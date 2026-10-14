import Config

# Workstation UI/tools only. runtime.exs selects the remote device to connect to.
# No firmware settings or local device services are loaded here.
if config_env() == :dev do
  config :nerves_gate, ec100_node: :"nerves_gate@100.88.166.70"

  config :nerves_gate, NervesGateWeb.Endpoint,
    url: [host: "localhost"],
    http: [ip: {127, 0, 0, 1}, port: 4000],
    code_reloader: true,
    debug_errors: true,
    live_reload: [
      patterns: [
        ~r"priv/static/.*(js|css)$",
        ~r"lib/nerves_gate_web/.*(ex|heex)$"
      ]
    ]

  config :phoenix_live_view, debug_heex_annotations: true, debug_attributes: true
end
