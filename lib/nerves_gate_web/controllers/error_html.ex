defmodule NervesGateWeb.ErrorHTML do
  @moduledoc false
  use NervesGateWeb, :html

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
