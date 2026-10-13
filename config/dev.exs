import Config

config :nerves_gate, ec100_node: :"nerves_gate@100.88.166.70"

# Imported only for MIX_TARGET=host, MIX_ENV=dev. Never enabled in firmware.
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
