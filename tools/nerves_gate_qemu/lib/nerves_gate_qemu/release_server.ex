defmodule NervesGateQEMU.ReleaseServer do
  @moduledoc "Host-side GitHub Releases fixture server with download fault injection."

  use Agent

  import Plug.Conn

  alias NervesGateQEMU.Runner

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_options),
    do: Agent.start_link(fn -> %{fault: :normal, index: "index.json"} end, name: __MODULE__)

  @spec normal() :: :ok
  def normal, do: Agent.update(__MODULE__, &%{&1 | fault: :normal})

  @spec truncate_after(pos_integer()) :: :ok
  def truncate_after(bytes) when is_integer(bytes) and bytes > 0,
    do: Agent.update(__MODULE__, &%{&1 | fault: {:truncate, bytes}})

  @spec corrupt() :: :ok
  def corrupt, do: Agent.update(__MODULE__, &%{&1 | fault: :corrupt})

  @spec select(String.t()) :: :ok
  def select(version) when is_binary(version),
    do: Agent.update(__MODULE__, &%{&1 | index: "index-#{version}.json", fault: :normal})

  @spec init(keyword()) :: keyword()
  def init(options), do: options

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(connection, _options) do
    case connection.path_info do
      ["repos", "sid2baker", "nerves_gate", "releases"] -> serve_index(connection)
      ["assets", name] -> serve_asset(connection, name)
      _other -> send_resp(connection, 404, "not found\n")
    end
  end

  defp serve_index(connection) do
    index = Agent.get(__MODULE__, & &1.index)

    case File.read(Path.join(Runner.release_root(), index)) do
      {:ok, contents} ->
        connection
        |> put_resp_content_type("application/json")
        |> send_resp(200, contents)

      {:error, :enoent} ->
        connection
        |> put_resp_content_type("application/json")
        |> send_resp(200, "[]")

      {:error, _reason} ->
        send_resp(connection, 500, "release fixture unavailable\n")
    end
  end

  defp serve_asset(connection, name) do
    path = Path.join(Runner.release_root(), Path.basename(name))

    if name == Path.basename(name) and File.regular?(path) do
      body = File.read!(path)
      fault = Agent.get(__MODULE__, & &1.fault)
      {status, body, headers} = range(connection, body)
      body = if String.ends_with?(name, ".fw"), do: faulted_body(body, fault), else: body

      connection
      |> put_resp_header("accept-ranges", "bytes")
      |> put_headers(headers)
      |> send_resp(status, body)
    else
      send_resp(connection, 404, "not found\n")
    end
  end

  defp range(connection, body) do
    total = byte_size(body)

    case get_req_header(connection, "range") do
      ["bytes=" <> value] ->
        case Integer.parse(String.trim_trailing(value, "-")) do
          {offset, ""} when offset >= 0 and offset < total ->
            ranged = binary_part(body, offset, total - offset)
            {206, ranged, [{"content-range", "bytes #{offset}-#{total - 1}/#{total}"}]}

          _invalid ->
            {416, <<>>, [{"content-range", "bytes */#{total}"}]}
        end

      _none ->
        {200, body, []}
    end
  end

  defp faulted_body(body, :normal), do: body

  defp faulted_body(body, {:truncate, bytes}),
    do: binary_part(body, 0, min(bytes, byte_size(body)))

  defp faulted_body(<<first, rest::binary>>, :corrupt),
    do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp faulted_body(body, :corrupt), do: body

  defp put_headers(connection, headers) do
    Enum.reduce(headers, connection, fn {key, value}, connection ->
      put_resp_header(connection, key, value)
    end)
  end
end
