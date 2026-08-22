defmodule NervesGate.Cluster.Discovery do
  @moduledoc "Fetches public cluster-group metadata from visible Tailnet gateways."

  @timeout 2_000

  @spec fetch(String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch(ipv4, options \\ []) when is_binary(ipv4) do
    timeout = Keyword.get(options, :timeout, @timeout)
    url = ~c"http://#{ipv4}/api/discovery"
    http_options = [timeout: timeout, connect_timeout: timeout]

    with {:ok, {{_version, 200, _reason}, _headers, body}} <-
           :httpc.request(:get, {url, []}, http_options, body_format: :binary),
         {:ok, %{"cluster_group" => group}} <- Jason.decode(body),
         {:ok, group} <- NervesGate.Cluster.Manager.validate_group(group) do
      {:ok, group}
    else
      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_discovery_response}
    end
  end
end
