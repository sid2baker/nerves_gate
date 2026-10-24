import Config

# Workstation credentials expire with the session and never enter its read model.
config :nerves_gate_workbench, WorkbenchWeb.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
