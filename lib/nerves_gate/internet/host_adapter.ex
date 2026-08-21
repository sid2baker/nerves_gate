defmodule NervesGate.Internet.HostAdapter do
  @moduledoc false
  @behaviour NervesGate.Internet.Adapter

  @impl true
  def configure_uplink(_config), do: :ok

  @impl true
  def clear(_interface), do: :ok

  @impl true
  def configure_commissioning(_interface, _options), do: :ok

  @impl true
  def snapshot(_interface), do: %{}
end
