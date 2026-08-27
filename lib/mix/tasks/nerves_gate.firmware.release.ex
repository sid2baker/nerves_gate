defmodule Mix.Tasks.NervesGate.Firmware.Release do
  @moduledoc """
  Signs a built firmware archive and emits its detached signed release manifest.

      mix nerves_gate.firmware.release \
        --firmware _build/x86_64_prod/nerves/images/nerves_gate.fw \
        --output dist \
        --private-key-file /run/secrets/fwup-key.priv

  The same Ed25519 key signs the fwup archive and the exact manifest bytes.
  Only its public half belongs in device firmware.
  """

  use Mix.Task

  @shortdoc "Create signed firmware artifacts for a GitHub Release"

  @switches [firmware: :string, output: :string, private_key_file: :string]

  @impl true
  def run(arguments) do
    {options, rest, invalid} = OptionParser.parse(arguments, strict: @switches)

    if rest != [] or invalid != [], do: Mix.raise(usage())

    firmware = Keyword.get(options, :firmware, default_firmware()) |> Path.expand()
    output = Keyword.get(options, :output, "dist") |> Path.expand()

    private_key_file =
      Keyword.get(options, :private_key_file) ||
        System.get_env("NERVES_GATE_FWUP_PRIVATE_KEY_FILE")

    if is_nil(private_key_file), do: Mix.raise("firmware signing key is required\n\n#{usage()}")
    unless File.regular?(firmware), do: Mix.raise("firmware archive not found: #{firmware}")

    metadata = metadata!(firmware)
    validate_metadata!(metadata)
    private_key = load_private_key!(private_key_file)
    public_key = binary_part(private_key, 32, 32)
    validate_trusted_key!(public_key)
    basename = artifact_basename(metadata)
    signed_path = Path.join(output, basename <> ".fw")
    manifest_path = Path.join(output, basename <> ".firmware.json")

    File.mkdir_p!(output)
    sign_firmware!(firmware, signed_path, private_key_file)
    verify_firmware!(signed_path, public_key)

    manifest = manifest(metadata, signed_path)
    manifest_contents = Jason.encode!(manifest, pretty: true) <> "\n"

    signature =
      :crypto.sign(:eddsa, :none, manifest_contents, [binary_part(private_key, 0, 32), :ed25519])

    File.write!(manifest_path, manifest_contents)
    File.write!(manifest_path <> ".sig", Base.encode64(signature))

    Mix.shell().info("Signed firmware release created:")
    Mix.shell().info("  #{signed_path}")
    Mix.shell().info("  #{manifest_path}")
    Mix.shell().info("  #{manifest_path}.sig")
  end

  defp metadata!(firmware) do
    case System.cmd("fwup", ["-m", "-i", firmware], stderr_to_stdout: true) do
      {output, 0} -> parse_metadata(output)
      {output, status} -> Mix.raise("fwup metadata failed (#{status}): #{String.trim(output)}")
    end
  end

  defp parse_metadata(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      ["meta-" <> key, value] = String.split(line, "=", parts: 2)
      {key, unquote_value(value)}
    end)
  end

  defp validate_metadata!(metadata) do
    required = ~w(product version uuid platform architecture misc vcs-identifier)
    missing = Enum.reject(required, &(is_binary(metadata[&1]) and metadata[&1] != ""))

    if missing != [], do: Mix.raise("firmware metadata is missing: #{Enum.join(missing, ", ")}")

    case Version.parse(metadata["version"]) do
      {:ok, _version} -> :ok
      :error -> Mix.raise("firmware version must be semantic: #{metadata["version"]}")
    end
  end

  defp load_private_key!(path) do
    case path |> File.read!() |> String.trim() |> Base.decode64() do
      {:ok, key} when byte_size(key) == 64 -> key
      _invalid -> Mix.raise("fwup private key must be one base64-encoded 64-byte Ed25519 key")
    end
  end

  defp validate_trusted_key!(public_key) do
    configured =
      System.get_env("NERVES_GATE_FWUP_PUBLIC_KEYS", "")
      |> String.split(",", trim: true)

    encoded = Base.encode64(public_key)

    if configured != [] and encoded not in configured do
      Mix.raise("signing key does not match any NERVES_GATE_FWUP_PUBLIC_KEYS entry")
    end
  end

  defp sign_firmware!(source, destination, private_key_file) do
    case System.cmd(
           "fwup",
           [
             "-S",
             "--private-key-file",
             Path.expand(private_key_file),
             "-i",
             source,
             "-o",
             destination
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("fwup signing failed (#{status}): #{String.trim(output)}")
    end
  end

  defp verify_firmware!(path, public_key) do
    case System.cmd(
           "fwup",
           ["-V", "--public-key", Base.encode64(public_key), "-i", path],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise("signed firmware verification failed (#{status}): #{String.trim(output)}")
    end
  end

  defp manifest(metadata, path) do
    %{
      "schema" => NervesGate.Firmware.Release.schema(),
      "product" => metadata["product"],
      "system" => metadata["misc"],
      "platform" => metadata["platform"],
      "architecture" => metadata["architecture"],
      "version" => metadata["version"],
      "uuid" => metadata["uuid"],
      "vcs_identifier" => metadata["vcs-identifier"],
      "artifact" => Path.basename(path),
      "size" => File.stat!(path).size,
      "sha256" => sha256(path)
    }
  end

  defp sha256(path) do
    path
    |> File.stream!(1024 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp artifact_basename(metadata) do
    product = String.replace(metadata["product"], ~r/[^a-zA-Z0-9._-]/, "-")
    platform = String.replace(metadata["platform"], ~r/[^a-zA-Z0-9._-]/, "-")
    "#{product}-#{metadata["version"]}-#{platform}"
  end

  defp unquote_value("\"" <> value), do: String.trim_trailing(value, "\"")
  defp unquote_value(value), do: value

  defp default_firmware do
    Path.join([Mix.Project.build_path(), "nerves", "images", "nerves_gate.fw"])
  end

  defp usage do
    "mix nerves_gate.firmware.release --firmware PATH --output DIR --private-key-file PATH"
  end
end
