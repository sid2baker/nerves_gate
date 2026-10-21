defmodule Dev.Release do
  @moduledoc false
  # Pure metadata tests may run with SSL code paths pruned by Mix. HTTP
  # verification starts :inets and :ssl before using these modules.
  @compile {:no_warn_undefined, [:public_key, :httpc]}
  @repo "sid2baker/nerves_gate"

  def metadata!(tag, root) do
    {project, app, version} =
      case tag do
        "sdk/v" <> version -> {"sdk", "nerves_gate_sdk", version}
        "v" <> version -> {".", "nerves_gate_dev", version}
        _ -> raise "Use sdk/vX.Y.Z or vX.Y.Z"
      end

    with {:ok, parsed} <- Version.parse(version),
         nil <- parsed.build do
      path = Path.join(root, project)

      unless String.trim(File.read!(Path.join(path, "VERSION"))) == version,
        do: raise("#{tag} disagrees with #{project}/VERSION")

      %{
        project: project,
        app: app,
        version: version,
        tag: tag,
        prerelease: parsed.pre != [],
        notes: notes!(File.read!(Path.join(path, "CHANGELOG.md")), version)
      }
    else
      _ -> raise "Use sdk/vX.Y.Z or vX.Y.Z without build metadata"
    end
  end

  def notes!(changelog, version) do
    lines = String.split(changelog, "\n")

    if Enum.any?(lines, &String.starts_with?(&1, ["```", "~~~"])),
      do: raise("Fenced changelog examples are not supported")

    prefix = "## #{version} - "

    case Enum.filter(lines, &String.starts_with?(&1, prefix)) do
      [heading] ->
        heading |> String.replace_prefix(prefix, "") |> Date.from_iso8601!()

        notes =
          lines
          |> Enum.drop_while(&(&1 != heading))
          |> tl()
          |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
          |> Enum.join("\n")
          |> String.trim()

        if notes == "", do: raise("Empty #{version} changelog section")
        notes

      _ ->
        raise "Add exactly one dated ## #{version} - YYYY-MM-DD changelog section"
    end
  end

  def prepare!(tag, root, output, notes_file) do
    info = metadata!(tag, root)
    File.write!(notes_file, info.notes)

    for key <- [:project, :app, :version, :tag, :prerelease] do
      File.write!(output, "#{key}=#{Map.fetch!(info, key)}\n", [:append])
    end

    info
  end

  def dependencies!(%{project: "."}, _root), do: :ok

  def dependencies!(info, root) do
    Mix.start()

    Mix.Project.in_project(String.to_atom(info.app), Path.join(root, info.project), fn _ ->
      invalid =
        for dep <- Mix.Project.config()[:deps],
            options = elem(dep, tuple_size(dep) - 1),
            is_list(options),
            Enum.any?([:path, :git, :github, :in_umbrella], &Keyword.has_key?(options, &1)),
            do: elem(dep, 0)

      unless invalid == [],
        do:
          raise(
            "Hex cannot publish Git/path dependencies: #{Enum.join(invalid, ", ")}. Resolve these before releasing; never silently omit them."
          )
    end)
  end

  # Refuse partial/existing releases instead of replacing immutable package bytes.
  # A failed job after publication requires an explicit, inspected repair.
  def unpublished!(info) do
    {json, status} =
      System.cmd("gh", ["api", "repos/#{@repo}/releases?per_page=100", "--paginate", "--slurp"],
        stderr_to_stdout: true
      )

    unless status == 0, do: raise("Cannot check existing GitHub releases")

    if json |> JSON.decode!() |> List.flatten() |> Enum.any?(&(&1["tag_name"] == info.tag)),
      do:
        raise("A GitHub release already exists for #{info.tag}; inspect and repair it explicitly")

    if info.project == "sdk", do: unpublished_hex!(info)
  end

  defp unpublished_hex!(info) do
    case get!("https://hex.pm/api/packages/#{info.app}/releases/#{info.version}") do
      {404, _} ->
        :ok

      {200, _} ->
        raise "#{info.app} #{info.version} already exists. Inspect and repair the release; do not republish or replace it."

      {status, _} ->
        raise "Hex registry preflight failed (HTTP #{status})"
    end
  end

  def verify!(info, notes_file) do
    if info.project == "sdk" do
      await!("Hex registry", fn ->
        match?({200, _}, get!("https://hex.pm/api/packages/#{info.app}/releases/#{info.version}"))
      end)

      await!("HexDocs", fn ->
        match?({200, _}, get!("https://hexdocs.pm/#{info.app}/#{info.version}/index.html"))
      end)
    end

    {body, 0} =
      System.cmd(
        "gh",
        [
          "release",
          "view",
          info.tag,
          "--repo",
          @repo,
          "--json",
          "name,tagName,body,isDraft,isPrerelease,assets"
        ],
        stderr_to_stdout: true
      )

    release = JSON.decode!(body)

    unless release["tagName"] == info.tag and release["name"] == info.tag and
             release["body"] == File.read!(notes_file) and release["isDraft"] == false and
             release["isPrerelease"] == info.prerelease,
           do: raise("GitHub release metadata does not match the canonical notes/tag")

    if release["assets"] != [], do: raise("Platform and SDK releases have no attached assets")
  end

  defp await!(label, ready?, attempts \\ 20) do
    cond do
      ready?.() ->
        :ok

      attempts > 1 ->
        Process.sleep(3_000)
        await!(label, ready?, attempts - 1)

      true ->
        raise "#{label} did not become public; inspect and repair the partial release"
    end
  end

  defp get!(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    options = [
      timeout: 15_000,
      connect_timeout: 5_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(url), [{~c"user-agent", ~c"nerves-gate-release"}]},
           options,
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} -> {status, body}
      {:error, reason} -> raise "Release verification HTTP request failed: #{inspect(reason)}"
    end
  end
end
