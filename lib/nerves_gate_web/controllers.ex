defmodule NervesGateWeb.StatusController do
  @moduledoc false
  use NervesGateWeb, :controller

  def show(connection, _params), do: json(connection, NervesGate.status())
end

defmodule NervesGateWeb.DiscoveryController do
  @moduledoc "Tailnet-only public metadata used for gateway group discovery."

  use NervesGateWeb, :controller

  def show(connection, _params), do: json(connection, NervesGate.discovery())
end

defmodule NervesGateWeb.ErrorHTML do
  @moduledoc false
  use NervesGateWeb, :html

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule NervesGateWeb.ErrorJSON do
  @moduledoc false

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
