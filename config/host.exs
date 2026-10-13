import Config

# Host runs only Phoenix; the backend node is selected before compilation.
backend_node = System.get_env("NERVES_GATE_BACKEND_NODE")

config :nerves_gate,
  target: :host,
  backend_node: if(backend_node, do: String.to_atom(backend_node))

if config_env() == :test, do: import_config("test.exs")
