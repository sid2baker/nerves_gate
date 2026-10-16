defmodule NervesGate.SSH.Keys do
  @moduledoc false
  @limit 32
  @max_bytes 8192
  @path "/data/nerves_gate/ssh_authorized_keys"
  @legacy_path "/data/nerves_ssh/default_user/authorized_keys"

  def path, do: @path

  # Accept exactly one plain OpenSSH public key. In particular, do not silently
  # discard authorized_keys restrictions (from=, command=, etc.) or private keys.
  def parse(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    text = String.trim(text)

    with true <- String.valid?(text) and not Regex.match?(~r/[\x00-\x1F\x7F]/u, text),
         [type, encoded | rest] <- String.split(text, ~r/ +/, parts: 3),
         true <-
           type in ~w(ssh-ed25519 ssh-rsa ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521),
         {:ok, _} <- Base.decode64(encoded),
         [{key, _}] <- :ssh_file.decode(type <> " " <> encoded, :auth_keys),
         canonical = :ssh_file.encode([{key, []}], :auth_keys) |> String.trim(),
         true <- canonical == type <> " " <> encoded do
      comment = Enum.join(rest)
      line = String.trim(canonical <> " " <> comment)

      {:ok,
       %{
         key: key,
         line: line,
         type: type,
         comment: comment,
         fingerprint: to_string(:ssh.hostkey_fingerprint(:sha256, key))
       }}
    else
      _ -> {:error, :invalid_ssh_key}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, MatchError, ErlangError] ->
      {:error, :invalid_ssh_key}
  end

  def parse(_), do: {:error, :invalid_ssh_key}

  def add(keys, text) do
    with {:ok, entry} <- parse(text) do
      cond do
        Enum.any?(keys, &(&1.fingerprint == entry.fingerprint)) -> {:ok, keys}
        length(keys) >= @limit -> {:error, :ssh_key_limit}
        true -> {:ok, keys ++ [entry]}
      end
    end
  end

  def load do
    case read(@path) do
      {:error, :enoent} -> seed()
      result -> result
    end
  end

  def save(keys) do
    data = Enum.map_join(keys, &(&1.line <> "\n"))
    directory = Path.dirname(@path)

    # Flush even an empty key file, then the rename and initial directory entry.
    # O_SYNC on writes alone does not make revocation durable across a hard reset.
    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(@path <> ".new", data),
         :ok <- File.chmod(@path <> ".new", 0o600),
         {:ok, :ok} <- File.open(@path <> ".new", [:read, :raw], &:file.sync/1),
         :ok <- File.rename(@path <> ".new", @path),
         :ok <- sync_directory(directory),
         :ok <- sync_directory(Path.dirname(directory)) do
      :ok
    else
      _ -> {:error, :ssh_keys_unavailable}
    end
  end

  defp sync_directory(directory) do
    # Directory descriptors are supported by OTP's primitive file driver, but
    # are not part of the File.open/:file.open contract.
    with {:ok, file} <- :prim_file.open(String.to_charlist(directory), [:read, :directory]) do
      try do
        :prim_file.sync(file)
      after
        :prim_file.close(file)
      end
    end
  end

  defp seed do
    # Import existing installations once. Once our file exists, even if empty,
    # deleted keys must not reappear after reboot or a firmware update.
    with {:ok, legacy} <- legacy(),
         {:ok, keys} <- parse_lines(legacy ++ Application.get_env(:nerves_gate, :ssh_keys, [])),
         :ok <- save(keys) do
      {:ok, keys}
    end
  end

  defp legacy do
    case read(@legacy_path) do
      {:ok, keys} -> {:ok, Enum.map(keys, & &1.line)}
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  defp read(path) do
    with {:ok, %{size: size}} when size <= @limit * (@max_bytes + 1) <- File.stat(path),
         {:ok, text} <- File.read(path) do
      parse_lines(String.split(text, "\n", trim: true))
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :ssh_keys_unavailable}
    end
  end

  defp parse_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, keys} ->
      case add(keys, line) do
        {:ok, keys} -> {:cont, {:ok, keys}}
        _ -> {:halt, {:error, :ssh_keys_unavailable}}
      end
    end)
  end
end
