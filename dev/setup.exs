defmodule Mix.Tasks.Setup.Qemu do
  @moduledoc false
  use Mix.Task

  # This task is loaded before deps.get; Req becomes available via deps.loadpaths.
  @compile {:no_warn_undefined, Req}
  @version "1.104.1"
  @archive_sha256 "108d1d96ecf410d305571e173516f27038f870919a9b89c914a167c6d33a4528"
  @tools ~w(git make cc pkg-config fwup docker qemu-system-x86_64 pasta unshare mount flock ip nft tc socat inotifywait)

  @impl true
  def run([]) do
    prerequisites!()
    Mix.Task.run("local.hex", ["--force", "--if-missing"])
    Mix.Task.run("local.rebar", ["--force", "--if-missing"])
    bootstrap!()
    Mix.Task.run("deps.get")
    Mix.Task.run("deps.loadpaths")
    {:ok, _} = Application.ensure_all_started(:req)
    tailscaled!()
    target_mix!(["deps.get"])

    Mix.shell().info(
      "Building the QEMU system (first build can take an hour; reruns are incremental)."
    )

    target_mix!(["nerves.artifact.build", "nerves_system_x86_64"])
    Mix.shell().info("Ready. Run mix dev.qemu, then open http://localhost:4000.")
  end

  def run(_), do: Mix.raise("Usage: mix setup")

  defp prerequisites! do
    unless :os.type() == {:unix, :linux} and
             String.starts_with?(to_string(:erlang.system_info(:system_architecture)), [
               "x86_64",
               "aarch64"
             ]) do
      Mix.raise(
        "QEMU development requires Linux x86_64 or aarch64. See docs/development.md#prerequisites."
      )
    end

    unless :erlang.system_info(:otp_release) == ~c"29" do
      Mix.raise("Use OTP 29 and Elixir 1.20; mise.toml pins the development toolchain.")
    end

    missing = Enum.reject(@tools, &System.find_executable/1)

    if missing != [] do
      Mix.raise(
        "Missing tools: #{Enum.join(missing, ", ")}. See docs/development.md#prerequisites."
      )
    end

    unless File.exists?("/dev/net/tun"), do: Mix.raise("QEMU requires /dev/net/tun on the host.")

    check!("docker", ["info"], "Docker must be running and accessible without sudo.")

    check!(
      "unshare",
      ~w(--user --map-root-user --net --mount --propagation private ip link set lo up),
      "Unprivileged user/network/mount namespaces must be enabled. No host networking was changed."
    )
  end

  defp check!(command, args, message) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("#{message}\n#{output}")
    end
  end

  defp bootstrap! do
    Application.load(:nerves_bootstrap)
    version = Application.spec(:nerves_bootstrap, :vsn)

    unless version && Version.match?(to_string(version), "~> 1.17") do
      Mix.Task.run("archive.install", ["hex", "nerves_bootstrap", "~> 1.17", "--force"])
    end
  end

  defp tailscaled! do
    archive = "tailscale_#{@version}_amd64.tgz"
    cache = Path.join("_build/setup", archive)
    File.mkdir_p!(Path.dirname(cache))

    data =
      case File.read(cache) do
        {:ok, data} ->
          data

        {:error, :enoent} ->
          Mix.shell().info("Downloading checksum-pinned x86 Tailscale #{@version}.")

          %{status: 200, body: data} =
            Req.get!("https://pkgs.tailscale.com/stable/#{archive}",
              decode_body: false,
              receive_timeout: 120_000
            )

          verify_archive!(data)
          File.write!(cache, data)
          data
      end

    verify_archive!(data)
    entry = String.to_charlist("tailscale_#{@version}_amd64/tailscaled")

    {:ok, [{^entry, binary}]} =
      :erl_tar.extract({:binary, data}, [:compressed, :memory, files: [entry]])

    path = "rootfs_overlay/x86_64/usr/sbin/tailscaled"

    case File.read(path) do
      {:ok, ^binary} ->
        :ok

      {:ok, _} ->
        Mix.raise(
          "#{path} differs from pinned Tailscale #{@version}. Remove it explicitly to replace it."
        )

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, binary)
    end

    File.chmod!(path, 0o755)
  end

  defp verify_archive!(data) do
    unless Base.encode16(:crypto.hash(:sha256, data), case: :lower) == @archive_sha256 do
      Mix.raise(
        "Tailscale archive checksum mismatch. Remove _build/setup/tailscale_#{@version}_amd64.tgz and retry."
      )
    end
  end

  defp target_mix!(args) do
    {_, status} =
      System.cmd("mix", args,
        env: [
          {"MIX_TARGET", "x86_64"},
          {"MIX_ENV", "dev"},
          {"NERVES_GATE_BACKEND_NODE", nil},
          {"NERVES_GATE_DEVICE_NODE", nil}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0,
      do: Mix.raise("x86 setup failed: mix #{Enum.join(args, " ")} (exit #{status})")
  end
end
