import Config

if config_target() == :host do
  # Launchers choose a device without changing the shared host compilation.
  backend_node = System.get_env("NERVES_GATE_BACKEND_NODE")

  config :nerves_gate, backend_node: if(backend_node, do: String.to_atom(backend_node))
end

if config_target() == :x86_64 do
  # The system sets the full disk serial as the hostname before Erlang starts.
  # Only the bench's distribution address is application-specific.
  {:ok, hostname} = :inet.gethostname()
  "qemu-" <> suffix = to_string(hostname)
  {index, ""} = Integer.parse(suffix)
  true = index in 2..254
  config :nerves_gate, development_node: :"nerves_gate@127.0.0.#{index}"
end

# No shared firmware secret. Sessions intentionally expire on reboot.
config :nerves_gate, NervesGateWeb.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
