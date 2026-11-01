# These host tests exercise a device's network contracts without starting one.
# Use the real QEMU declarations, not a second list of Ethernet names.
config = Config.Reader.read!("config/config.exs", env: :dev, target: :x86_64)
Application.put_env(:nerves_gate, :board, config[:nerves_gate][:board])

ExUnit.start()
