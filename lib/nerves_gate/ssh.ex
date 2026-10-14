defmodule NervesGate.SSH do
  @moduledoc "Device-owned SSH public keys. Commands persist before changing authentication."
  use GenServer
  alias NervesGate.{Error, Observations}
  alias NervesGate.SSH.Keys

  @behaviour :ssh_server_key_api

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)
  def add_key(key), do: GenServer.call(__MODULE__, {:add, key})
  def remove_key(fingerprint), do: GenServer.call(__MODULE__, {:remove, fingerprint})
  def observe, do: Observations.subscribe([{Observations.table(), ["ssh"]}])

  def unavailable,
    do: %{available: false, keys: [], error: Error.from(:ssh_keys_unavailable)}

  # NervesSSH supplies its persisted host keys to custom callbacks. Only user
  # authorization is ours; the console, SFTP and firmware subsystem stay unchanged.
  @impl :ssh_server_key_api
  def host_key(algorithm, options) do
    case options[:key_cb_private][:host_keys] do
      %{^algorithm => key} -> {:ok, key}
      _ -> {:error, :enoent}
    end
  end

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
        {:ok, keys} -> %{keys: keys, loaded: true, error: nil}
        {:error, _} -> %{keys: [], loaded: false, error: :ssh_keys_unavailable}
      end

    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}

  def handle_call({:authorized?, key}, _, state),
    do: {:reply, Enum.any?(state.keys, &(&1.key == key)), state}

  def handle_call(_, _, %{loaded: false} = state),
    do: {:reply, {:error, :ssh_keys_unavailable}, state}

  def handle_call({:add, text}, _, state) do
    case Keys.add(state.keys, text) do
      {:ok, keys} -> save(keys, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:remove, fingerprint}, _, state) do
    if Enum.any?(state.keys, &(&1.fingerprint == fingerprint)),
      do: save(Enum.reject(state.keys, &(&1.fingerprint == fingerprint)), state),
      else: {:reply, {:error, :ssh_key_not_found}, state}
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
      error: state.error && Error.from(state.error)
    }
  end

  defp publish(state) do
    Observations.put(["ssh", "keys"], public(state))
    state
  end
end
