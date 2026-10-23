defmodule NervesGate.Network.CellularPIN do
  @moduledoc """
  Private, SIM-bound PIN storage. Never put a record in domain state or projections.

  The owner-only file is not encrypted. Root access and full data-partition
  backups can read it. Consuming a PIN durably blocks further automatic attempts
  before returning the credential; only a known-successful PIN operation
  may save and arm it again. Observing READY alone must never re-arm it.
  """

  import Bitwise

  # Both firmware targets mount persistent ext4 at /root; /data is its BSP
  # symlink. Use the canonical mount so all credential-path symlinks can be refused.
  @path "/root/nerves_gate/cellular/pin.json"
  @max_bytes 1024
  @error {:error, :cellular_pin_storage}

  @doc false
  def save(pin, identity, path \\ @path) do
    with true <- valid_pin?(pin) and valid_identity?(identity),
         {:ok, _} <- load(path) do
      persist(%{pin: pin, fingerprint: fingerprint(identity), armed: true}, path)
    else
      _ -> @error
    end
  end

  @doc false
  def block(path \\ @path) do
    case load(path) do
      {:ok, nil} -> :ok
      {:ok, record} -> persist(%{record | armed: false}, path)
      _ -> @error
    end
  end

  @doc false
  def consume(identity, path \\ @path) do
    with {:ok, record} when not is_nil(record) <- load(path),
         :ready <- state(record, identity),
         :ok <- persist(%{record | armed: false}, path) do
      {:ok, record.pin}
    else
      {:ok, nil} -> {:error, :cellular_pin_not_saved}
      state when is_atom(state) -> {:error, :cellular_auto_unlock_blocked}
      _ -> @error
    end
  end

  @doc false
  def forget(path \\ @path) do
    with :ok <- safe_directory(Path.dirname(path)),
         :ok <- safe_file(path),
         :ok <- discard_temp(path <> ".new"),
         :ok <- remove(path) do
      :ok
    else
      _ -> @error
    end
  end

  @doc false
  def metadata(identity \\ nil, path \\ @path) do
    case load(path) do
      {:ok, nil} -> %{pin_saved: false, auto_unlock: :off}
      {:ok, record} -> %{pin_saved: true, auto_unlock: state(record, identity)}
      _ -> %{pin_saved: nil, auto_unlock: :storage_error}
    end
  end

  defp state(%{armed: false}, _), do: :blocked

  defp state(record, identity) do
    cond do
      not valid_identity?(identity) -> :identity_unknown
      record.fingerprint != fingerprint(identity) -> :different_sim
      true -> :ready
    end
  end

  defp load(path) do
    with :ok <- safe_directory(Path.dirname(path)),
         :ok <- safe_file(path) do
      case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
        {:error, :enoent} -> {:ok, nil}
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_bytes -> decode(bytes)
        _ -> @error
      end
    else
      _ -> @error
    end
  end

  defp decode(bytes) do
    with {:ok, %{"version" => 1, "pin" => pin, "fingerprint" => hash, "armed" => armed} = data} <-
           Jason.decode(bytes),
         true <- map_size(data) == 4 and valid_pin?(pin) and is_boolean(armed),
         true <- is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) do
      {:ok, %{pin: pin, fingerprint: hash, armed: armed}}
    else
      _ -> @error
    end
  end

  defp persist(record, path) do
    directory = Path.dirname(path)
    temp = path <> ".new"

    with :ok <- prepare_directory(directory),
         :ok <- safe_file(path),
         :ok <- discard_temp(temp) do
      try do
        with :ok <- write_private(temp, record),
             :ok <- File.rename(temp, path),
             :ok <- sync_directory(directory) do
          :ok
        else
          _ -> @error
        end
      after
        File.rm(temp)
      end
    else
      _ -> @error
    end
  end

  defp write_private(path, record) do
    bytes =
      Jason.encode!(%{
        version: 1,
        pin: record.pin,
        fingerprint: record.fingerprint,
        armed: record.armed
      })

    # The directory is already 0700. Set 0600 before writing any secret bytes.
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- :file.write(file, bytes) do
            :file.sync(file)
          end
        after
          :file.close(file)
        end

      error ->
        error
    end
  end

  defp prepare_directory(directory) do
    with :ok <- safe_directory(directory),
         :ok <- ensure_directory(directory) do
      safe_directory(directory)
    end
  end

  defp ensure_directory(directory) do
    case File.lstat(directory) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        with :ok <- ensure_directory(Path.dirname(directory)),
             :ok <- File.mkdir(directory),
             :ok <- File.chmod(directory, 0o700) do
          sync_directory(Path.dirname(directory))
        end

      _ ->
        @error
    end
  end

  # Check every ancestor without following symlinks. Only the credential directory
  # itself must be private; /data and the ordinary application directory need not be.
  defp safe_directory(directory) do
    ancestors = directory |> Path.expand() |> Path.split() |> Enum.scan(&Path.join(&2, &1))

    if Enum.all?(ancestors, &safe_ancestor?(&1, Path.expand(directory))), do: :ok, else: @error
  end

  defp safe_ancestor?(ancestor, directory) do
    case File.lstat(ancestor) do
      {:ok, %{type: :directory, mode: mode}} ->
        ancestor != directory or band(mode, 0o777) == 0o700

      {:error, :enoent} ->
        true

      _ ->
        false
    end
  end

  defp safe_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode, size: size, links: 1}}
      when band(mode, 0o777) == 0o600 and size <= @max_bytes ->
        :ok

      {:error, :enoent} ->
        :ok

      _ ->
        @error
    end
  end

  # A killed writer may leave this one private staging file. Never read it as a
  # credential, and remove it on both the next write and explicit forget.
  defp discard_temp(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1, size: 0}} ->
        remove(path)

      _ ->
        with :ok <- safe_file(path), do: remove(path)
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> sync_directory(Path.dirname(path))
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      {:ok, file} ->
        try do
          :file.sync(file)
        after
          :file.close(file)
        end

      error ->
        error
    end
  end

  defp valid_pin?(pin), do: is_binary(pin) and Regex.match?(~r/\A[0-9]{4,8}\z/, pin)

  defp valid_identity?(identity),
    do: is_binary(identity) and Regex.match?(~r/\A[0-9]{18,22}\z/, identity)

  defp fingerprint(identity), do: :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)
end
