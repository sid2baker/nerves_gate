defmodule Mix.Tasks.Ec100.Release do
  use Mix.Task

  @shortdoc "Collect EC100 system, license, and source release assets"
  @moduledoc """
  Run after `mix nerves.artifact.build` on Linux with Docker.

  Writes the system tarball, source tarball, and SHA256SUMS into an empty `dist/`.
  Nerves 2 pre.3 does not run the legacy build_runner_opts legal-info target.
  """

  alias Nerves.Container

  @impl Mix.Task
  def run([]) do
    unless match?({:unix, :linux}, :os.type()) and Container.tool() == "docker" do
      Mix.raise("Release asset collection requires Linux and Docker")
    end

    package = Nerves.BuildPlan.find_package(Nerves.build_plan(), :nerves_system_ec100)
    name = "nerves_system_ec100-portable-#{package.version}-#{package.source_fingerprint}"
    sources = "nerves_system_ec100-sources-#{package.version}-#{package.source_fingerprint}"

    unless File.regular?(Path.join(package.download_path, "#{name}.tar.gz")) do
      Mix.raise("Run mix nerves.artifact.build before collecting release assets")
    end

    File.mkdir_p!("dist")

    if File.ls!("dist") != [],
      do: Mix.raise("dist must be empty before collecting release assets")

    dl_dir = Nerves.Paths.download_dir()
    artifact_dir = Path.relative_to(package.download_path, dl_dir)
    image = Container.package_image!("docker", package)

    args =
      ["run", "--rm"] ++
        Container.container_user_args("docker") ++
        Container.work_mount_args("docker", package) ++
        Container.download_mount_args("docker", dl_dir) ++
        [
          "--env",
          "NERVES_BR_DL_DIR=/workspace/dl",
          "--env",
          "NERVES_ARTIFACT_VERSION=#{package.version}",
          "--env",
          "NERVES_ARTIFACT_SOURCE_FINGERPRINT=#{package.source_fingerprint}",
          "--env",
          "NERVES_ARTIFACT_DIR=/workspace/dl/#{artifact_dir}",
          "--entrypoint",
          "/bin/bash",
          image,
          "/workspace/nerves_system_ec100/release/assets.sh"
        ]

    {_, status} =
      System.cmd("docker", args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    if status != 0, do: Mix.raise("Release asset collection failed (#{status})")

    filenames = ["#{name}.tar.gz", "#{sources}.tar.gz"]

    for filename <- filenames do
      source = Path.join(package.download_path, filename)

      if File.stat!(source).size >= 2_147_483_648,
        do: Mix.raise("#{filename} exceeds GitHub's 2 GiB limit")

      File.cp!(source, Path.join("dist", filename))
    end

    {checksums, 0} = System.cmd("sha256sum", filenames, cd: "dist")
    File.write!("dist/SHA256SUMS", checksums)
    Mix.shell().info("Release assets and SHA256SUMS are in dist/")
  end
end
