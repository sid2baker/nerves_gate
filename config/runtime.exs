import Config

# Workstation credentials expire with the session and never enter its read model.
for {app, endpoint} <- [
      {:nerves_gate, NervesGateWeb.Endpoint},
      {:nerves_gate_dev, DevWeb.Endpoint}
    ] do
  config app, endpoint, secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
end
