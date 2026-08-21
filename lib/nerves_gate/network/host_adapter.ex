defmodule NervesGate.Network.HostAdapter do
  @moduledoc false
  @behaviour NervesGate.Network.Adapter

  @impl true
  def configure_uplink(_config), do: :ok

  @impl true
  def clear(_interface), do: :ok

  @impl true
  def configure_commissioning(_interface, _options), do: :ok

  @impl true
  def snapshot(_interface), do: %{}
end
