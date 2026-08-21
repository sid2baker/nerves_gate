defmodule NervesGateWeb.LocalAccess do
  @moduledoc "Restricts setup to local commissioning networks and the dashboard to Tailscale."

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(options), do: options

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{remote_ip: ip} = connection, options) do
    mode = Keyword.get(options, :mode, :management)

    if allowed?(mode, ip) do
      connection
    else
      connection
      |> send_resp(403, "NervesGate is only available from the tailnet\n")
      |> halt()
    end
  end

  @spec tailnet?(:inet.ip_address()) :: boolean()
  def tailnet?({127, _b, _c, _d}), do: true
  def tailnet?({100, second, _c, _d}) when second in 64..127, do: true
  def tailnet?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def tailnet?({0xFD7A, 0x115C, 0xA1E0, _d, _e, _f, _g, _h}), do: true
  def tailnet?(_ip), do: false

  @spec setup?(:inet.ip_address()) :: boolean()
  def setup?({192, 168, third, _d}) when third in 77..90, do: true
  def setup?(ip), do: tailnet?(ip)

  @spec ip_string(:inet.ip_address()) :: String.t()
  def ip_string(ip), do: ip |> :inet.ntoa() |> to_string()

  defp allowed?(:tailnet, ip), do: tailnet?(ip)
  defp allowed?(:setup, ip), do: setup?(ip)

  defp allowed?(:home, ip) do
    case NervesGate.Setup.status() do
      %{ready: true} -> tailnet?(ip)
      _setup -> setup?(ip)
    end
  catch
    :exit, _reason -> setup?(ip)
  end

  defp allowed?(:management, ip), do: setup?(ip)
end
