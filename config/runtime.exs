import Config

if config_target() == :host do
  # Launchers choose a device without changing the shared host compilation.
  backend_node =
    System.get_env("NERVES_GATE_BACKEND_NODE") ||
      if(config_env() == :test, do: "nerves_gate@192.168.77.2")

  config :nerves_gate, backend_node: if(backend_node, do: String.to_atom(backend_node))
end

# No shared firmware secret. Sessions intentionally expire on reboot.
config :nerves_gate, NervesGateWeb.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
