[
  import_deps: [:phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  subdirectories: ["sdk", "sim", "firmware"],
  inputs: ["mix.exs", ".formatter.exs", "{config,lib,test,priv,scripts}/**/*.{ex,exs}"]
]
