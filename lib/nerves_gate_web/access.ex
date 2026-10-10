defmodule NervesGateWeb.Access do
  @moduledoc false

  # Phoenix signs this session into the LiveView token. Host/forwarded headers
  # are deliberately ignored; USB exemption also checks the live socket peer.
  def session(conn) do
    %{address: address} = Plug.Conn.get_sock_data(conn)
    %{"local_address" => address |> :inet.ntoa() |> to_string()}
  end
end
