[
  import_deps: [:phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  subdirectories: ["sdk", "firmware", "plugins/tailnet_subrouter", "plugins/modbus"],
  inputs: ["mix.exs", ".formatter.exs", "{config,lib,test,priv,scripts}/**/*.{ex,exs}"]
]
