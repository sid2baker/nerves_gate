import Config

# Host builds provide quality checks, asset builds and the shared gateway UI.
# Start no device services here. Explicit simulator launchers set :services to
# [Dev.GatewayInit, NervesGateWeb.Endpoint] and start the host application.
# VintageNet behaviours/types are compiled but their applications never start.
config :nerves_gate, services: []

# Stable entry names let firmware use Phoenix static paths without loading Volt.
config :volt,
  entry: "assets/js/app.js",
  root: "assets",
  sources: ["**/*.js"],
  outdir: "priv/static/assets",
  resolve_dirs: ["deps"],
  target: :es2020,
  format: :esm,
  hash: false,
  code_splitting: false,
  sourcemap: false,
  tailwind: [
    css: "assets/css/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      # The shared stylesheet serves the device and developer workbench.
      %{base: "../lib/", pattern: "**/*.ex"},
      %{base: "assets/", pattern: "**/*.js"}
    ]
  ]
