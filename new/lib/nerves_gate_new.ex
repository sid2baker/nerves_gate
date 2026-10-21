defmodule NervesGateNew do
  @moduledoc false
  @reserved ~w(nerves_gate nerves_gate_sdk nerves_gate_sim nerves_gate_new nerves_gate_workspace)

  def workspace(path, source \\ nil) do
    name = Path.basename(Path.expand(path))
    validate_name!(name)
    absent!(path)
    render("workspace", path, name: name, module: Macro.camelize(name), source: source)
    app(Path.join(path, "apps"), "my_app", source)
  end

  def app(apps_dir, name, source \\ nil) do
    validate_name!(name)
    if name in @reserved, do: Mix.raise("#{name} is a platform application name")
    path = Path.join(apps_dir, name)
    absent!(path)
    render("app", path, app: name, module: Macro.camelize(name), source: source)
  end

  def validate_name!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name),
      do: Mix.raise("Names must contain lowercase letters, digits and underscores")
  end

  defp absent!(path) do
    if File.exists?(path), do: Mix.raise("Refusing to overwrite #{path}")
  end

  defp render(kind, path, binding) do
    templates = Application.app_dir(:nerves_gate_new, "priv/templates/#{kind}")

    for template <- Path.wildcard(Path.join(templates, "**/*"), match_dot: true),
        File.regular?(template) do
      relative = template |> Path.relative_to(templates) |> String.trim_trailing(".eex")
      relative = String.replace(relative, "app_name", Keyword.get(binding, :app, ""))
      # Mix archives omit hidden files; keep template sources visible.
      relative =
        case relative do
          "formatter.exs" -> ".formatter.exs"
          "gitignore" -> ".gitignore"
          other -> other
        end

      destination = Path.join(path, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, EEx.eval_file(template, binding))
      Mix.shell().info([:green, "* creating ", :reset, destination])
    end
  end
end
