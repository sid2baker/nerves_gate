defmodule NervesGateQEMU.Gateway do
  @moduledoc "HTTP client and canonical-state queries for one QEMU gateway."

  alias NervesGateQEMU.Runner

  @schema "nerves_gate.status.v3"
  @timeout 3_000

  @spec fetch(Runner.device()) :: {:ok, map()} | {:error, term()}
  def fetch(device), do: fetch_url(device.status_url)

  @spec fetch_url(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_url(url) do
    request = {String.to_charlist(url), []}
    options = [timeout: @timeout, connect_timeout: @timeout]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> decode_status(body)
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec command(Runner.device(), String.t(), map(), timeout()) :: :ok | {:error, term()}
  def command(device, command, params, timeout \\ 180_000) do
    command_at(device.status_url, command, params, timeout)
  end

  @spec command_at(String.t(), String.t(), map(), timeout()) :: :ok | {:error, term()}
  def command_at(base_url, command, params, timeout \\ 180_000) do
    request_command(command_url(base_url, "/api/configuration", command), params, timeout)
  end

  @spec firmware_command(Runner.device(), String.t(), map(), timeout()) ::
          :ok | {:error, term()}
  def firmware_command(device, command, params, timeout \\ 180_000) do
    with {:ok, status} <- fetch(device),
         address when is_binary(address) <- get_in(status, ["local", "state", "tailnet", "ipv4"]) do
      base_url = "http://#{address}/api/status"
      request_command(command_url(base_url, "/api/firmware", command), params, timeout)
    else
      nil -> {:error, :tailnet_address_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp request_command(url, params, timeout) do
    request = {
      String.to_charlist(url),
      [{~c"content-type", ~c"application/json"}],
      ~c"application/json",
      Jason.encode!(params)
    }

    options = [timeout: timeout, connect_timeout: @timeout]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        decode_command(body)

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:http, status, command_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec state(map()) :: map()
  def state(status), do: get_in(status, ["local", "state"]) || %{}

  @spec configured?(map()) :: boolean()
  def configured?(status),
    do: get_in(status, ["local", "state", "configuration", "configured"]) == true

  @spec ready?(map()) :: boolean()
  def ready?(status) do
    configured?(status) and layer(status, "internet") == "online" and
      layer(status, "tailnet") == "online" and layer(status, "cluster") == "online"
  end

  @spec firmware(map()) :: map()
  def firmware(status), do: get_in(status, ["local", "state", "firmware"]) || %{}

  @spec device_id(map()) :: String.t() | nil
  def device_id(status), do: get_in(status, ["local", "state", "device", "device_id"])

  @spec boot_id(map()) :: String.t() | nil
  def boot_id(status), do: get_in(status, ["local", "boot_id"])

  @spec accepted_revision(map()) :: non_neg_integer() | nil
  def accepted_revision(status),
    do: get_in(status, ["local", "state", "configuration", "current", "revision"])

  @spec replica(map(), String.t()) :: map() | nil
  def replica(status, device_id), do: get_in(status, ["replicas", device_id])

  @spec summary(map()) :: map()
  def summary(status) do
    %{
      configured: configured?(status),
      revision: get_in(status, ["local", "revision"]),
      boot_id: boot_id(status),
      internet: layer(status, "internet"),
      tailnet: layer(status, "tailnet"),
      cluster: layer(status, "cluster"),
      replicas:
        Map.new(Map.get(status, "replicas", %{}), fn {id, replica} ->
          {id, %{connected: replica["connected"], revision: replica["revision"]}}
        end)
    }
  end

  defp decode_command(body) do
    case Jason.decode(body) do
      {:ok, %{"ok" => true}} -> :ok
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, _invalid} -> {:error, :invalid_command_response}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp command_error(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _invalid -> :invalid_command_response
    end
  end

  defp command_url(status_url, prefix, command) do
    encoded_command =
      command
      |> String.split("/", trim: true)
      |> Enum.map_join("/", &URI.encode/1)

    status_url
    |> URI.parse()
    |> Map.put(:path, "#{prefix}/#{encoded_command}")
    |> Map.put(:query, nil)
    |> URI.to_string()
  end

  defp decode_status(body) do
    case Jason.decode(body) do
      {:ok, %{"schema" => @schema} = status} -> {:ok, status}
      {:ok, %{"schema" => schema}} -> {:error, {:unsupported_schema, schema}}
      {:ok, _invalid} -> {:error, :invalid_status}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp layer(status, name), do: get_in(status, ["local", "state", name, "state"])
end
