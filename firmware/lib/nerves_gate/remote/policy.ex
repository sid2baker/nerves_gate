defmodule NervesGate.Remote.Policy do
  @moduledoc "Pure command admission, public observation filtering and daemon outcome interpretation."
  alias NervesGate.Error

  def unavailable do
    %{
      available: false,
      simulated: false,
      state: "unavailable",
      auth_state: "unknown",
      hostname: nil,
      dns_name: nil,
      ipv4: nil,
      version: nil,
      advertised_routes: nil,
      health: [],
      operation: nil,
      error: nil,
      verified: false,
      time_synchronized: false,
      permitted_routes: nil,
      sharing: %{ready: false, uncertain: []}
    }
  end

  def validate(:connect, %{"hostname" => name, "auth_key" => key} = params)
      when map_size(params) == 2 do
    with {:ok, params} <- validate(:connect, %{"hostname" => name}) do
      if is_binary(key) and byte_size(key) in 1..4096 and String.valid?(key) and
           String.trim(key) != "" do
        {:ok, Map.put(params, :auth_key, key)}
      else
        {:error,
         Error.new("invalid_parameters", "Enter a Tailscale auth key (up to 4096 bytes).")}
      end
    end
  end

  def validate(operation, params) when operation in [:connect, :configure] do
    case params do
      %{"hostname" => name} when map_size(params) == 1 and is_binary(name) ->
        if String.valid?(name) and
             Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, name),
           do: {:ok, %{hostname: String.downcase(name)}},
           else:
             {:error,
              Error.new(
                "invalid_parameters",
                "Use 1–63 letters, numbers or hyphens for the device name. Start and end with a letter or number."
              )}

      _ ->
        {:error, Error.new("invalid_parameters", "Supply only the device name.")}
    end
  end

  def validate(:disconnect, params) when params == %{},
    do: {:ok, %{}}

  def validate(_, _), do: {:error, Error.new("invalid_parameters", "Invalid Tailscale command.")}

  def available(remote, operation \\ nil)

  def available(%{operation: operation}, _) when not is_nil(operation),
    do: {:error, Error.new("remote_busy", "A Tailscale change is still running.")}

  def available(%{available: true, time_synchronized: true}, :connect), do: :ok

  def available(%{available: true}, :connect),
    do: {:error, Error.new("time_unsynchronized", "Waiting for system time synchronization.")}

  def available(%{available: true}, _), do: :ok

  def available(_, _),
    do:
      {:error,
       Error.new("remote_unavailable", "Tailscale is starting or unavailable. Try again shortly.")}

  # Optimistic concurrency for editors: reject a draft based on an old hostname.
  def expected(_, :any), do: :ok
  def expected(%{hostname: hostname}, hostname), do: :ok

  def expected(_, _),
    do:
      {:error,
       Error.new(
         "stale_remote",
         "The device name changed in another session. Reload before saving."
       )}

  # Serve needs an enrolled, online DNS identity. One attempt per name prevents
  # observation updates from replaying failed writes or racing another command.
  def serve_dns_name(
        %{
          available: true,
          state: "online",
          auth_state: "authenticated",
          dns_name: dns_name,
          operation: nil,
          error: nil
        },
        attempted
      )
      when is_binary(dns_name) and dns_name != "" and dns_name != attempted,
      do: dns_name

  def serve_dns_name(_, _), do: nil

  def sanitize(observed) do
    defaults = unavailable()

    defaults
    |> Map.merge(Map.take(observed, Map.keys(defaults)))
    |> Map.update!(:health, fn warnings ->
      for warning <- List.wrap(warnings), is_binary(warning) do
        warning
        |> String.replace(~r/https?:\/\/[^\s<>"']+/i, "[private URL]")
        |> String.replace(~r/tskey-[A-Za-z0-9_-]+/, "[private key]")
      end
    end)
  end

  def login_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil}
      when host in ["login.tailscale.com", "controlplane.tailscale.com"] ->
        url

      _ ->
        nil
    end
  end

  def login_url(_), do: nil

  def result_error(:ok), do: nil
  def result_error({:ok, _private_url}), do: nil
  def result_error({:error, :needs_approval}), do: nil

  def result_error({:error, :timeout}),
    do:
      Error.new(
        "remote_timeout",
        "Tailscale stopped responding. The change may still complete; check its status before retrying."
      )

  def result_error(
        {:error,
         %{
           code: "outcome_unknown",
           message: "The command reply was lost. Read the current state before retrying."
         }}
      ),
      do:
        Error.new(
          "remote_outcome_unknown",
          "Tailscale operation was interrupted. Some settings may have changed; check its status before retrying."
        )

  def result_error(_),
    do:
      Error.new(
        "remote_failed",
        "Tailscale could not complete the change. Check the connection and try again. Some settings may have changed."
      )
end
