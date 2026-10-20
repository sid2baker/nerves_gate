defmodule NervesGate.Dev.Tailscaled do
  @moduledoc false
  # Installs the checksum-pinned x86 tailscaled into the x86_64 (QEMU) firmware
  # overlay. Loaded by `mix tailscaled.install` without compiling the project, so
  # it uses OTP's HTTP client with verified TLS. EC100 needs a qualified ARM build.

  @version "1.104.1"
  @archive_sha256 "108d1d96ecf410d305571e173516f27038f870919a9b89c914a167c6d33a4528"
  @archive "tailscale_#{@version}_amd64.tgz"
  @cache Path.expand("../_build/setup/#{@archive}", __DIR__)
  @path Path.expand("../rootfs_overlay/x86_64/usr/sbin/tailscaled", __DIR__)

  def install do
    entry = String.to_charlist("tailscale_#{@version}_amd64/tailscaled")

    {:ok, [{^entry, binary}]} =
      :erl_tar.extract({:binary, archive()}, [:compressed, :memory, files: [entry]])

    case File.read(@path) do
      {:ok, ^binary} ->
        :ok

      {:ok, _} ->
        Mix.raise(
          "#{@path} differs from pinned Tailscale #{@version}. Remove it explicitly to replace it."
        )

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(@path))
        File.write!(@path, binary)
    end

    File.chmod!(@path, 0o755)
  end

  defp archive do
    case File.read(@cache) do
      {:ok, data} ->
        verify!(data)

      {:error, :enoent} ->
        Mix.shell().info("Downloading checksum-pinned x86 Tailscale #{@version}.")
        data = verify!(download("https://pkgs.tailscale.com/stable/#{@archive}"))
        File.mkdir_p!(Path.dirname(@cache))
        File.write!(@cache, data)
        data
    end
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, [ssl: ssl, timeout: 120_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> body
      _ -> Mix.raise("Cannot download #{url}. Check Internet access and retry.")
    end
  end

  defp verify!(data) do
    if Base.encode16(:crypto.hash(:sha256, data), case: :lower) == @archive_sha256,
      do: data,
      else: Mix.raise("Tailscale archive checksum mismatch. Remove #{@cache} and retry.")
  end
end
