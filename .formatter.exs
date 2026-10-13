[
  import_deps: [:phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["mix.exs", "{config,lib,test,rootfs_overlay}/**/*.{ex,exs}"],
  excludes: ["test/support/nerves_system_x86_64/{deps,_build}/**/*.{ex,exs}"]
]
