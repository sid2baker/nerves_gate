import Config

# Workstation sessions intentionally expire when the simulator stops.
for endpoint <- [NervesGateWeb.Endpoint, NervesGateWeb.Simulator.Endpoint] do
  config :nerves_gate, endpoint, secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
end
