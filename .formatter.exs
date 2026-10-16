[
  import_deps: [:phoenix_live_view],
  plugins:
    [Phoenix.LiveView.HTMLFormatter] ++ if(Mix.target() == :host, do: [Volt.Formatter], else: []),
  inputs:
    ["{mix,.formatter}.exs", "{config,lib,dev,firmware,test,rootfs_overlay}/**/*.{ex,exs}"] ++
      if(Mix.target() == :host, do: ["assets/js/**/*.js"], else: []),
  volt: [semi: false, single_quote: false, trailing_comma: :none]
]
