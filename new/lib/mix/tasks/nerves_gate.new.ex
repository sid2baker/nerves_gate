defmodule Mix.Tasks.NervesGate.New do
  use Mix.Task

  @shortdoc "Generate a portable Nerves Gate OTP application"
  @moduledoc """
  `mix nerves_gate.new my_app` creates an independent Mix project using the SDK,
  with the QEMU simulator tools in development. It does not fetch dependencies,
  install tools or start devices.
  """

  @impl true
  def run([path]) do
    app = Path.basename(Path.expand(path))

    unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, app),
      do: Mix.raise("Application name must contain lowercase letters, digits and underscores")

    if app in ~w(nerves_gate nerves_gate_sdk nerves_gate_sim nerves_gate_new),
      do: Mix.raise("#{app} is a platform application name")

    if File.exists?(path), do: Mix.raise("Refusing to overwrite #{path}")

    binding = [app: app, module: Macro.camelize(app)]
    templates = Application.app_dir(:nerves_gate_new, "priv/templates")

    for template <- Path.wildcard(Path.join(templates, "**/*"), match_dot: true),
        File.regular?(template) do
      relative = template |> Path.relative_to(templates) |> String.trim_trailing(".eex")
      destination = Path.join(path, String.replace(relative, "app_name", app))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, EEx.eval_file(template, binding))
      Mix.shell().info([:green, "* creating ", :reset, destination])
    end

    Mix.shell().info("""

    Next:
      cd #{path}
      mix deps.get
      mix test
      mix nerves_gate.sim --firmware path/to/nerves_gate.fw
      mix nerves_gate.sim.install
      mix nerves_gate.package
    """)
  end

  def run(_), do: Mix.raise("Usage: mix nerves_gate.new my_app")
end
