defmodule NervesGateWeb.StatusController do
  @moduledoc false
  use NervesGateWeb, :controller

  def show(connection, _params) do
    json(connection, NervesGate.Status.api_snapshot())
  end
end
