defmodule NervesGate.QemuInit do
  @moduledoc false

  # QEMU hardware initialization only. The serial is burned into each disposable
  # disk, not into the shared firmware. EC100 never loads this hook.
  def child_spec(args), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}}

  def start_link(_) do
    :mounted = Nerves.Runtime.Init.init_application_partition()
    "qemu-" <> suffix = serial = Nerves.Runtime.serial_number()
    {index, ""} = Integer.parse(suffix)
    true = index in 2..254
    Application.put_env(:nerves_gate, :development_node, :"nerves_gate@127.0.0.#{index}")
    {_, 0} = System.cmd("ip", ~w"link set eth3 down")
    {_, 0} = System.cmd("ip", ~w"link set eth3 name usb0")
    config = Application.fetch_env!(:vintage_net, :config)

    Application.put_env(:vintage_net, :config, [
      {"usb0", %{type: VintageNetDirect, vintage_net_direct: %{hostname: serial}}} | config
    ])

    :ignore
  end
end
