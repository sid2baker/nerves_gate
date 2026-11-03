defmodule NervesGate.SSH.Keys do
  @moduledoc false
  @limit 32
  @max_bytes 8192
  @key ["ssh", "authorized_keys"]

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
      _ ->
        {:error,
         %{
           code: "invalid_ssh_key",
           message:
             "Paste one OpenSSH public key (Ed25519, RSA or ECDSA), without key options. Never paste a private key."
         }}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, MatchError, ErlangError] ->
      {:error,
       %{
         code: "invalid_ssh_key",
         message:
           "Paste one OpenSSH public key (Ed25519, RSA or ECDSA), without key options. Never paste a private key."
       }}
  end

  def parse(_),
    do:
      {:error,
       %{
         code: "invalid_ssh_key",
         message:
           "Paste one OpenSSH public key (Ed25519, RSA or ECDSA), without key options. Never paste a private key."
       }}

  def add(keys, text) do
    with {:ok, entry} <- parse(text) do
      cond do
        Enum.any?(keys, &(&1.fingerprint == entry.fingerprint)) ->
          {:ok, keys}

        length(keys) >= @limit ->
          {:error,
           %{
             code: "ssh_key_limit",
             message: "The 32-key limit has been reached. Remove an unused key first."
           }}

        true ->
          {:ok, keys ++ [entry]}
      end
    end
  end

  def load do
    case NervesGate.Settings.get(@key) do
      nil -> seed()
      lines when is_list(lines) and length(lines) <= @limit -> parse_lines(lines)
      _ -> unavailable()
    end
  end

  # A persisted empty list stays empty, so a removed key is never restored.
  def save(keys) do
    case NervesGate.Settings.put(@key, Enum.map(keys, & &1.line)) do
      :ok -> :ok
      _ -> unavailable()
    end
  end

  defp unavailable,
    do:
      {:error,
       %{
         code: "ssh_keys_unavailable",
         message: "SSH keys could not be read or saved. Existing keys have not been replaced."
       }}

  # Seed only from the current firmware configuration, once.
  defp seed do
    with {:ok, keys} <- parse_lines(Application.get_env(:nerves_gate, :ssh_keys, [])),
         :ok <- save(keys) do
      {:ok, keys}
    end
  end

  defp parse_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, keys} ->
      case add(keys, line) do
        {:ok, keys} -> {:cont, {:ok, keys}}
        _ -> {:halt, unavailable()}
      end
    end)
  end
end
