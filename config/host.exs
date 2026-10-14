import Config

# Host runs only Phoenix; the backend node is selected before compilation.
# Test sessions use the actual QEMU backend, never local device services.
backend_node =
  System.get_env("NERVES_GATE_BACKEND_NODE") ||
    if(config_env() == :test, do: "nerves_gate@192.168.77.2")

config :nerves_gate,
  target: :host,
  backend_node: if(backend_node, do: String.to_atom(backend_node))
