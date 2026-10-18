defmodule NervesGate.TailnetAuth do
  @moduledoc "GitHub OIDC credentials and run-scoped cleanup for the opt-in QEMU tailnet scenario."

  @tag "tag:ci"

  def client do
    unless System.get_env("GITHUB_ACTIONS") == "true",
      do: fail("Real authentication requires the GitHub Actions OIDC workflow.")

    audience = env!("TS_AUDIENCE")
    client_id = env!("TS_OAUTH_CLIENT_ID")
    request_token = env!("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    {:ok, _} = Application.ensure_all_started(:req)

    jwt =
      request(:get, env!("ACTIONS_ID_TOKEN_REQUEST_URL"),
        auth: {:bearer, request_token},
        params: [audience: audience]
      )
      |> body!("GitHub OIDC token request")
      |> field!("value")
      |> mask()

    token =
      request(:post, "https://api.tailscale.com/api/v2/oauth/token-exchange",
        form: [client_id: client_id, jwt: jwt]
      )
      |> body!("Tailscale OIDC token exchange; check the trust credential's claims and scopes")
      |> field!("access_token")
      |> mask()

    Req.new(base_url: "https://api.tailscale.com/api/v2", auth: {:bearer, token})
  end

  def prefix do
    run = env!("GITHUB_RUN_ID")
    attempt = env!("GITHUB_RUN_ATTEMPT")

    unless run =~ ~r/\A[0-9]+\z/ and attempt =~ ~r/\A[0-9]+\z/,
      do: fail("Invalid GitHub run identity.")

    "ng-ci-#{run}-#{attempt}"
  end

  def key_request(hostname) do
    %{
      capabilities: %{
        devices: %{
          create: %{reusable: false, ephemeral: true, preauthorized: true, tags: [@tag]}
        }
      },
      expirySeconds: 600,
      description: hostname
    }
  end

  # No credential-bearing call or response is allowed to escape into an assertion.
  def enroll(client, vm, hostname) do
    remember(hostname, nil)

    body =
      api(client, :post, "/tailnet/-/keys", json: key_request(hostname))
      |> body!("Creating a single-use Tailscale auth key")

    remember(hostname, field!(body, "id"))
    key = body |> field!("key") |> mask()

    connect(vm, hostname, key)
  end

  defp connect(vm, hostname, key) do
    result = :erpc.call(vm.node, NervesGate, :remote_connect, [hostname, [auth_key: key]], 15_000)
    unless result == :ok, do: fail("Guest rejected authentication admission.")
    :ok
  catch
    _, _ -> fail("Guest enrollment failed; inspect sanitized device status. No key was replayed.")
  end

  def node_id(client, hostname, address) do
    Enum.find_value(devices(client), fn device ->
      if device["hostname"] == hostname and device["authorized"] == true and
           device["isEphemeral"] == true and @tag in (device["tags"] || []) and
           address in (device["addresses"] || []) do
        device["nodeId"]
      end
    end)
  end

  # The journal contains only names and key IDs, never tokens or auth keys. It lets
  # an always() CI step clean up after a killed scenario worker or failed launcher.
  def cleanup do
    case File.read(journal_path()) do
      {:error, :enoent} ->
        :ok

      {:ok, data} ->
        resources = journal!(data)
        client = client()
        names = resources["names"]

        # Revoke every recorded key even if device listing/deletion later fails.
        results = Enum.map(resources["keys"], &revoke_key(client, &1, names))
        nodes_removed = remove_nodes(client, names)

        unless Enum.all?(results) and nodes_removed,
          do:
            fail("Tailnet cleanup incomplete for #{prefix()}; inspect these test nodes and keys.")

        File.rm!(journal_path())
        :ok

      _ ->
        fail("Cannot read the tailnet resource journal; inspect #{prefix()} in the tailnet.")
    end
  end

  defp revoke_key(client, id, names) do
    path = "/tailnet/-/keys/#{id}"

    case api(client, :get, path) do
      {404, _} ->
        true

      {200, %{"description" => description}} ->
        description in names and deleted?(api(client, :delete, path))

      _ ->
        false
    end
  end

  @doc false
  def owned_node?(device, names),
    do:
      device["hostname"] in names and device["isEphemeral"] == true and
        @tag in (device["tags"] || [])

  defp remove_nodes(client, names) do
    case api(client, :get, "/tailnet/-/devices") do
      {200, %{"devices" => devices}} when is_list(devices) ->
        results =
          devices
          |> Enum.filter(&owned_node?(&1, names))
          |> Enum.map(&remove_node(client, &1))

        Enum.all?(results) and nodes_absent?(client, names)

      _ ->
        false
    end
  end

  defp remove_node(client, %{"nodeId" => id}) when is_binary(id),
    do: deleted?(api(client, :delete, "/device/#{URI.encode_www_form(id)}"))

  defp remove_node(_, _), do: false

  defp nodes_absent?(client, names) do
    case api(client, :get, "/tailnet/-/devices") do
      {200, %{"devices" => devices}} when is_list(devices) ->
        not Enum.any?(devices, &(&1["hostname"] in names))

      _ ->
        false
    end
  end

  defp devices(client) do
    case api(client, :get, "/tailnet/-/devices") |> body!("Reading test node registrations") do
      %{"devices" => devices} when is_list(devices) -> devices
      _ -> fail("Invalid Tailscale devices response.")
    end
  end

  defp remember(hostname, key) do
    path = journal_path()

    resources =
      case File.read(path) do
        {:ok, data} -> journal!(data)
        {:error, :enoent} -> %{"names" => [], "keys" => []}
        _ -> fail("Cannot read the tailnet resource journal.")
      end

    resources = %{
      "names" => Enum.uniq([hostname | resources["names"]]),
      "keys" => if(key, do: Enum.uniq([key | resources["keys"]]), else: resources["keys"])
    }

    # Validate before writing so cleanup can never target arbitrary resources.
    data = JSON.encode!(resources)
    journal!(data)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", data)
    File.rename!(path <> ".tmp", path)
  end

  defp journal!(data), do: resources!(data, prefix())

  @doc false
  def resources!(data, expected) do
    allowed = Enum.map(1..3, fn i -> "#{expected}-#{i}" end)

    with {:ok, %{"names" => names, "keys" => keys} = resources} <- JSON.decode(data),
         true <- is_list(names) and is_list(keys),
         true <- Enum.count_until(names, 4) <= 3 and Enum.count_until(keys, 4) <= 3,
         true <- Enum.all?(names, &(&1 in allowed)),
         true <- Enum.all?(keys, &(is_binary(&1) and &1 =~ ~r/\A[a-zA-Z0-9_-]+\z/)) do
      resources
    else
      _ -> fail("Invalid tailnet resource journal; no resources were deleted.")
    end
  end

  defp journal_path, do: Path.join("_build/qemu-tests", "#{prefix()}.json")

  defp api(client, method, path, options \\ []) do
    request(method, client, Keyword.put(options, :url, path))
  end

  defp request(method, client, options) do
    options =
      Keyword.merge(options,
        method: method,
        retry: false,
        redirect: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 15_000
      )

    case Req.request(client, options) do
      {:ok, response} -> {response.status, response.body}
      _ -> :request_failed
    end
  catch
    _, _ -> :request_failed
  end

  defp body!({status, body}, _) when status in 200..299 and is_map(body), do: body

  defp body!({status, _}, operation),
    do: fail("#{operation} failed (HTTP #{status}); response withheld.")

  defp body!(_, operation),
    do: fail("#{operation} failed; outcome may be unknown. No request was replayed.")

  defp deleted?({status, _}), do: status in 200..299 or status == 404
  defp deleted?(_), do: false

  defp field!(body, key) do
    case body[key] do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> fail("Invalid authentication response; contents withheld.")
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> fail("Missing #{name}; configure the tailnet-ci GitHub environment.")
    end
  end

  # Do not tee this workflow's stdout to files: these are GitHub masking commands.
  defp mask(value) do
    escaped =
      value
      |> String.replace("%", "%25")
      |> String.replace("\r", "%0D")
      |> String.replace("\n", "%0A")

    IO.puts("::add-mask::#{escaped}")
    value
  end

  defp fail(message), do: raise(message)
end
