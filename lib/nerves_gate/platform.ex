defmodule NervesGate.Platform do
  @moduledoc false
  use GenServer

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    if Nerves.Runtime.mix_target() != :host, do: configure_forwarding()

    {:ok, %{}}
  end

  defp configure_forwarding do
    write_sysctl("/proc/sys/net/ipv4/ip_forward")
    write_sysctl("/proc/sys/net/ipv6/conf/all/forwarding")
  end

  defp write_sysctl(path) do
    case File.write(path, "1\n") do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end
end
