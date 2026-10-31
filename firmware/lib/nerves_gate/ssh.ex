defmodule NervesGate.SSH do
  @moduledoc "Device-owned SSH public keys. Commands persist before changing authentication."
  use GenServer
  alias NervesGate.{Error, Observations}
  alias NervesGate.SSH.Keys

  @behaviour :ssh_server_key_api

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def status do
    NervesGate.Error.read(fn -> GenServer.call(__MODULE__, :status) end, &unavailable/0)
  end

  def add_key(key), do: Error.protect(fn -> GenServer.call(__MODULE__, {:add, key}) end)

  def remove_key(fingerprint),
    do: Error.protect(fn -> GenServer.call(__MODULE__, {:remove, fingerprint}) end)

  def observe, do: Observations.subscribe([{Observations.table(), ["ssh"]}])

  def unavailable,
    do: %{
      available: false,
      keys: [],
      error: %{
        code: "ssh_keys_unavailable",
        message: "SSH keys could not be read or saved. Existing keys have not been replaced."
      }
    }

  # NervesSSH creates the host-key files; let OTP load their supported format.
  # Only user authorization is ours, not host-key generation or storage.
  @impl :ssh_server_key_api
  defdelegate host_key(algorithm, options), to: :ssh_file

  @doc """
  SHA-256 fingerprints of the host keys the SSH daemon serves. Workbench reads them
  over authenticated distribution and pins them for firmware upload. Key material
  never leaves this function.
  """
  def host_key_fingerprints do
    options = [system_dir: String.to_charlist(Application.fetch_env!(:nerves_ssh, :system_dir))]

    fingerprints =
      for algorithm <- :ssh.default_algorithms()[:public_key],
          {:ok, private} <- [host_key(algorithm, options)],
          uniq: true,
          do: private |> :ssh_file.extract_public_key() |> fingerprint()

    if fingerprints == [], do: {:error, :host_key_unavailable}, else: {:ok, fingerprints}
  catch
    _, _ -> {:error, :host_key_unavailable}
  end

  defp fingerprint(public), do: to_string(:ssh.hostkey_fingerprint(:sha256, public))

  @impl :ssh_server_key_api
  def is_auth_key(key, _user, _options) do
    GenServer.call(__MODULE__, {:authorized?, key})
  catch
    :exit, {_, {GenServer, :call, _}} -> false
  end

  @impl true
  def init(_) do
    state =
      case Keys.load() do
        {:ok, keys} ->
          %{keys: keys, loaded: true, error: nil}

        {:error, _} ->
          %{
            keys: [],
            loaded: false,
            error: %{
              code: "ssh_keys_unavailable",
              message:
                "SSH keys could not be read or saved. Existing keys have not been replaced."
            }
          }
      end

    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}

  def handle_call({:authorized?, key}, _, state),
    do: {:reply, Enum.any?(state.keys, &(&1.key == key)), state}

  def handle_call(_, _, %{loaded: false} = state),
    do:
      {:reply,
       {:error,
        %{
          code: "ssh_keys_unavailable",
          message: "SSH keys could not be read or saved. Existing keys have not been replaced."
        }}, state}

  def handle_call({:add, text}, _, state) do
    case Keys.add(state.keys, text) do
      {:ok, keys} -> save(keys, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:remove, fingerprint}, _, state) do
    if Enum.any?(state.keys, &(&1.fingerprint == fingerprint)),
      do: save(Enum.reject(state.keys, &(&1.fingerprint == fingerprint)), state),
      else:
        {:reply,
         {:error,
          %{
            code: "ssh_key_not_found",
            message: "This SSH key is no longer present. Refresh the key list."
          }}, state}
  end

  defp save(keys, state) do
    case Keys.save(keys) do
      :ok -> {:reply, :ok, publish(%{state | keys: keys, error: nil})}
      {:error, reason} = error -> {:reply, error, publish(%{state | error: reason})}
    end
  end

  defp public(state) do
    %{
      available: state.loaded,
      keys: Enum.map(state.keys, &Map.take(&1, [:fingerprint, :type, :comment])),
      error: state.error && Error.safe(state.error)
    }
  end

  defp publish(state) do
    Observations.put(["ssh", "keys"], public(state))
    state
  end

  @doc false
  def available(%{available: true}), do: :ok

  def available(_),
    do:
      {:error,
       %{
         code: "ssh_keys_unavailable",
         message: "SSH keys could not be read or saved. Existing keys have not been replaced."
       }}
end
