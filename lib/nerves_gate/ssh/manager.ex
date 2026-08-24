defmodule NervesGate.SSH.Manager do
  @moduledoc """
  Owns the NervesSSH listener and follows the observed Tailnet address.

  A listener is created only for a concrete IPv4 address in Tailscale's
  100.64.0.0/10 range. Missing, wildcard, and ordinary LAN/WLAN addresses are
  rejected before keyless authentication options are constructed.
  """

  use GenServer

  alias NervesGate.SSH.Alarms
  alias NervesGate.Storage
  alias NervesGate.Tailnet.Address
  alias NervesGate.Tailnet.Observer
  alias NervesSSH.Options

  @port 22
  @retry_delay 1_000

  defstruct [
    :starter,
    :stopper,
    :publisher,
    :alarm_reporter,
    :tailnet,
    :listener,
    :monitor,
    :retry_timer,
    :last_error,
    enabled: false
  ]

  @type state_name :: :disabled | :waiting_for_tailnet | :listening | :error
  @type status :: %{
          enabled: boolean(),
          state: state_name(),
          address: :inet.ip4_address() | nil,
          port: 22
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec set_enabled(boolean(), GenServer.server()) :: :ok
  def set_enabled(enabled, server \\ __MODULE__) when is_boolean(enabled) do
    GenServer.call(server, {:set_enabled, enabled}, 15_000)
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    if Keyword.get(options, :subscribe, true) do
      Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")
    end

    tailnet =
      case Keyword.get(options, :tailnet, &Observer.status/0) do
        function when is_function(function, 0) -> function.()
        status when is_map(status) -> status
      end

    state = %__MODULE__{
      enabled: Keyword.get(options, :enabled, false),
      tailnet: tailnet,
      starter: Keyword.get(options, :starter, &start_daemon/1),
      stopper: Keyword.get(options, :stopper, &stop_daemon/1),
      publisher: Keyword.get(options, :publisher, &publish/1),
      alarm_reporter: Keyword.get(options, :alarm_reporter, &Alarms.report/1)
    }

    state = reconcile(state)
    state.alarm_reporter.(public_status(state))
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:set_enabled, enabled}, _from, state) do
    previous = public_status(state)
    state = state |> Map.put(:enabled, enabled) |> reconcile()
    publish_if_changed(previous, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tailnet_changed, tailnet}, state) when is_map(tailnet) do
    previous = public_status(state)
    state = state |> Map.put(:tailnet, tailnet) |> reconcile()
    publish_if_changed(previous, state)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, reference, :process, pid, reason},
        %{monitor: reference, listener: %{pid: pid}} = state
      ) do
    previous = public_status(state)

    state =
      state
      |> Map.merge(%{listener: nil, monitor: nil, last_error: {:listener_stopped, reason}})
      |> schedule_retry()

    publish_if_changed(previous, state)
    {:noreply, state}
  end

  def handle_info(:retry, state) do
    previous = public_status(state)
    state = state |> Map.put(:retry_timer, nil) |> reconcile()
    publish_if_changed(previous, state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> cancel_retry() |> stop_listener()
    :ok
  end

  defp reconcile(%{enabled: false} = state) do
    state
    |> cancel_retry()
    |> stop_listener()
    |> Map.put(:last_error, nil)
  end

  defp reconcile(%{enabled: true} = state) do
    case tailnet_address(state.tailnet) do
      nil ->
        state
        |> cancel_retry()
        |> stop_listener()
        |> Map.put(:last_error, nil)

      address ->
        reconcile_address(state, address)
    end
  end

  defp reconcile_address(%{listener: %{address: address}} = state, address), do: state

  defp reconcile_address(%{listener: listener} = state, address) when not is_nil(listener) do
    state |> stop_listener() |> start_listener(address)
  end

  defp reconcile_address(state, address), do: start_listener(state, address)

  defp start_listener(state, address) do
    if Address.ipv4?(address) do
      state = cancel_retry(state)

      case state.starter.(ssh_options(address)) do
        {:ok, pid} when is_pid(pid) ->
          %{
            state
            | listener: %{pid: pid, address: address},
              monitor: Process.monitor(pid),
              last_error: nil
          }

        {:error, reason} ->
          state
          |> Map.merge(%{listener: nil, monitor: nil, last_error: reason})
          |> schedule_retry()

        invalid ->
          state
          |> Map.merge(%{
            listener: nil,
            monitor: nil,
            last_error: {:invalid_start_result, invalid}
          })
          |> schedule_retry()
      end
    else
      state |> stop_listener() |> Map.put(:last_error, :invalid_tailnet_address)
    end
  end

  defp stop_listener(%{listener: nil} = state), do: %{state | monitor: nil}

  defp stop_listener(state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    :ok = state.stopper.(state.listener.pid)
    %{state | listener: nil, monitor: nil}
  end

  defp schedule_retry(%{enabled: true, retry_timer: nil} = state) do
    if tailnet_address(state.tailnet) do
      %{state | retry_timer: Process.send_after(self(), :retry, @retry_delay)}
    else
      state
    end
  end

  defp schedule_retry(state), do: state

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(state) do
    Process.cancel_timer(state.retry_timer)
    %{state | retry_timer: nil}
  end

  defp public_status(%{enabled: false}) do
    %{enabled: false, state: :disabled, address: nil, port: @port}
  end

  defp public_status(%{enabled: true, listener: %{address: address}}) do
    %{enabled: true, state: :listening, address: address, port: @port}
  end

  defp public_status(%{enabled: true, last_error: error}) when not is_nil(error) do
    %{enabled: true, state: :error, address: nil, port: @port}
  end

  defp public_status(%{enabled: true}) do
    %{enabled: true, state: :waiting_for_tailnet, address: nil, port: @port}
  end

  defp publish_if_changed(previous, state) do
    current = public_status(state)
    state.alarm_reporter.(current)
    if current != previous, do: state.publisher.(current)
    :ok
  end

  defp tailnet_address(%{online: true, ipv4: ipv4}) when is_binary(ipv4) do
    case Address.parse_ipv4(ipv4) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  defp tailnet_address(_tailnet), do: nil

  defp ssh_options(address) do
    Options.new(
      name: NervesGate.SSH.Daemon,
      authorized_keys: [],
      user_passwords: [],
      port: @port,
      subsystems: [],
      system_dir: Storage.path("nerves_ssh"),
      user_dir: Path.join(System.tmp_dir!(), "nerves_gate_ssh"),
      shell: :elixir,
      exec: :disabled,
      daemon_option_overrides: [inet: :inet, ip: address, no_auth_needed: true]
    )
    |> Options.sanitize()
  end

  defp start_daemon(options) do
    child_spec = %{
      id: NervesGate.SSH.Daemon,
      start: {NervesSSH, :start_link, [options]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(NervesGate.SSH.DynamicSupervisor, child_spec) do
      {:ok, pid} ->
        case daemon_info(options.name) do
          {:ok, _info} ->
            {:ok, pid}

          {:error, reason} ->
            stop_daemon(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp daemon_info(name) do
    NervesSSH.info(name)
  catch
    :exit, reason -> {:error, {:daemon_start_failed, reason}}
  end

  defp stop_daemon(pid) do
    case DynamicSupervisor.terminate_child(NervesGate.SSH.DynamicSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp publish(status) do
    Phoenix.PubSub.local_broadcast(NervesGate.PubSub, "ssh", {:ssh_changed, status})
  end
end
