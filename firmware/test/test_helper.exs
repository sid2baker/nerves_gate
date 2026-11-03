# These host tests exercise a device's network contracts without starting one.
# Use the real QEMU declarations, not a second list of Ethernet names.
config = Config.Reader.read!("config/config.exs", env: :dev, target: :x86_64)
Application.put_env(:nerves_gate, :board, config[:nerves_gate][:board])

# The application does not start on the host. Tests start the services they
# exercise; these two are shared by every endpoint and plugin UI test. Stop them
# afterwards: the root `mix check` runs this suite inside the workbench test VM.
{:ok, shared} =
  Supervisor.start_link([{Phoenix.PubSub, name: NervesGate.PubSub}, NervesGate.Plugins.UI],
    strategy: :one_for_one
  )

# after_suite callbacks outlive this suite in the shared VM, so stop only once.
ExUnit.after_suite(fn _ -> if Process.alive?(shared), do: Supervisor.stop(shared) end)
ExUnit.start()
