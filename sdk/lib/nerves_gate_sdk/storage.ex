defmodule NervesGateSDK.Storage do
  @moduledoc "SD storage observations and plugin-owned data directories."
  alias NervesGateSDK.Backend

  defmodule Status do
    @moduledoc "Availability of plugin storage. Platform state does not require an SD card."
    @enforce_keys [:available?]
    defstruct [:available?, :free_bytes]
    @type t :: %__MODULE__{available?: boolean(), free_bytes: non_neg_integer() | nil}
  end

  @spec status() :: {:ok, Status.t()} | {:error, term()}
  def status, do: Backend.call(:storage_status, [])

  @doc "Returns the managed plugin's data directory. The calling PID must belong to that activation and supply its main OTP application name."
  @spec data_dir(atom()) :: {:ok, Path.t()} | {:error, term()}
  def data_dir(app) when is_atom(app) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, Atom.to_string(app)),
      do: Backend.call(:storage_data_dir, [app]),
      else: {:error, :invalid_application}
  end

  def data_dir(_), do: {:error, :invalid_application}

  @doc """
  Atomically replace the calling plugin version's configuration term.

  The platform derives plugin and version from the calling process, which must
  belong to the running activation. One opaque term per version, at most 1 MiB
  serialized; the plugin owns its structure. Other versions' terms are kept and
  never loaded automatically. A failed save leaves the previous term or none.
  `{:error, :commit_unknown}` means the new term may or may not be durable.
  Concurrent saves from one plugin are last-writer-wins; serialize them if order matters.
  """
  @spec save_config(term()) :: :ok | {:error, term()}
  def save_config(term), do: Backend.call(:storage_save_config, [term])

  @doc """
  Restore this plugin version's term. Decoding refuses atoms/functions unknown
  to the running system and malformed files (`{:error, :invalid_configuration}`).
  """
  @spec restore_config() :: {:ok, term()} | :not_found | {:error, term()}
  def restore_config, do: Backend.call(:storage_restore_config, [])

  @doc "Delete only this plugin version's term."
  @spec delete_config() :: :ok | :not_found | {:error, term()}
  def delete_config, do: Backend.call(:storage_delete_config, [])
end
