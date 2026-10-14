defmodule NervesGateWeb.Access do
  @moduledoc false

  # Phoenix signs this session into the LiveView token. Host/forwarded headers
  # are deliberately ignored; USB exemption also checks the live socket peer.
  def session(conn) do
    %{address: address} = Plug.Conn.get_sock_data(conn)

    local =
      case :inet.ntoa(address) do
        {:error, _} -> nil
        ip -> to_string(ip)
      end

    %{"local_address" => local}
  end
end
