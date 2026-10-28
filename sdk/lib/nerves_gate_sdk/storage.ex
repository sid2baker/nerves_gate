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
end
