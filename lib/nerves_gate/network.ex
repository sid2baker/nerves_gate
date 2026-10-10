defmodule NervesGate.Network do
  @moduledoc """
  Internal LAN executor and browser-independent, 60-second trial safety boundary.
  Client adapters should use `NervesGate.Device`, not these low-level commands.
  """
  use GenServer
  alias NervesGate.Config

  @callback apply_config(map(), term()) :: :ok | {:error, term()}
  @callback snapshot(term()) :: map()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def propose(network, server \\ __MODULE__), do: GenServer.call(server, {:propose, network})
  def confirm(id, server \\ __MODULE__), do: GenServer.call(server, {:confirm, id})
  def cancel(id, server \\ __MODULE__), do: GenServer.call(server, {:cancel, id})
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, "network")

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Config.path())

    {config, error} =
      case Config.load(path) do
        {:ok, config} -> {config, nil}
        {:error, reason} -> {nil, {:load, reason}}
      end

    state = %{
      config: config,
      error: error,
      path: path,
      adapter:
        Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :network_adapter)),
      trial: nil,
      recovering: false,
      observed: nil,
      trial_ms: Keyword.get(opts, :trial_ms, 60_000),
      poll_ms: Keyword.get(opts, :poll_ms, 1_000)
    }

    # Unconfirmed settings are never written. Process/VM restart restores the last commit.
    state = if config, do: restore(state), else: state
    {:ok, refresh(state), {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    schedule_poll(state)
    {:noreply, publish(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call({:propose, _}, _from, %{config: nil} = state),
    do: {:reply, {:error, :invalid_saved_config}, state}

  def handle_call({:propose, _}, _from, %{trial: trial} = state) when not is_nil(trial),
    do: {:reply, {:error, :trial_in_progress}, state}

  def handle_call({:propose, _}, _from, %{recovering: true} = state),
    do: {:reply, {:error, :recovery_in_progress}, state}

  def handle_call({:propose, network}, _from, state) do
    with {:ok, network} <- Config.validate_network(network),
         # Make even first-run defaults durable BEFORE touching an interface.
         :ok <- Config.save(state.config, state.path) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      timer = Process.send_after(self(), {:expire, id}, state.trial_ms)

      trial = %{
        id: id,
        network: network,
        deadline: now() + state.trial_ms,
        expires_at: System.system_time(:millisecond) + state.trial_ms,
        timer: timer
      }

      state = %{state | trial: trial, error: nil}

      case apply_network(state, network) do
        :ok ->
          {:reply, {:ok, id}, publish(refresh(state))}

        {:error, reason} ->
          state = rollback(state, {:apply, reason})
          {:reply, {:error, {:apply, reason}}, publish(refresh(state))}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:confirm, id}, _from, %{trial: %{id: id} = trial} = state) do
    state = refresh(state)

    cond do
      now() >= trial.deadline ->
        {:reply, {:error, :expired}, publish(rollback(state, :expired))}

      not ready?(state.observed, trial.network) ->
        {:reply, {:error, :not_connected}, state}

      true ->
        config = %{state.config | "network" => trial.network, "setup_completed" => true}

        case Config.save(config, state.path) do
          :ok ->
            Process.cancel_timer(trial.timer)
            {:reply, :ok, publish(%{state | config: config, trial: nil, error: nil})}

          {:error, reason} ->
            {:reply, {:error, {:save, reason}}, publish(rollback(state, {:save, reason}))}
        end
    end
  end

  def handle_call({:cancel, id}, _from, %{trial: %{id: id}} = state),
    do: {:reply, :ok, publish(refresh(rollback(state, nil)))}

  def handle_call({action, _}, _from, state) when action in [:confirm, :cancel],
    do: {:reply, {:error, :no_matching_trial}, state}

  @impl true
  def handle_info({:expire, id}, %{trial: %{id: id}} = state),
    do: {:noreply, publish(refresh(rollback(state, :expired)))}

  def handle_info({:expire, _}, state), do: {:noreply, state}

  def handle_info(:poll, state) do
    next = if state.recovering, do: restore(state), else: state
    next = refresh(next)
    if public(next) != public(state), do: publish(next)
    schedule_poll(next)
    {:noreply, next}
  end

  defp rollback(state, reason) do
    if state.trial, do: Process.cancel_timer(state.trial.timer)
    restore(%{state | trial: nil, error: reason})
  end

  defp restore(state) do
    case apply_network(state, state.config["network"]) do
      :ok ->
        error = if match?({:restore, _}, state.error), do: nil, else: state.error
        %{state | recovering: false, error: error}

      {:error, reason} ->
        %{state | recovering: true, error: {:restore, reason}}
    end
  end

  defp apply_network(%{adapter: {module, context}}, network) do
    module.apply_config(network, context)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp refresh(%{adapter: {module, context}} = state) do
    %{state | observed: module.snapshot(context)}
  catch
    kind, reason -> %{state | observed: nil, error: {:discovery, {kind, reason}}}
  end

  @doc "Local readiness only; user confirmation verifies the management path, not internet reachability."
  def ready?(%{bridge: bridge, ports: ports}, network) do
    bridge.present and bridge.link and bridge.state == :configured and
      bridge.method == network["ip_method"] and
      Enum.any?(ports, &(&1.present and &1.link and &1.master == "br0")) and
      Enum.all?(ports, &(not &1.present or &1.master == "br0")) and
      Enum.any?(bridge.addresses, fn %{address: address, prefix_length: prefix} ->
        case network["ip_method"] do
          "dhcp" ->
            match?({:ok, {a, _, _, _}} when a > 0 and a < 224 and a != 127, Config.ipv4(address))

          "static" ->
            address == network["static_ip"] and
              Config.prefix_length(network["subnet_mask"]) == {:ok, prefix}
        end
      end)
  end

  def ready?(_, _), do: false

  defp public(state) do
    %{
      config: state.config,
      trial: if(state.trial, do: Map.drop(state.trial, [:timer, :deadline])),
      observed: state.observed,
      error: state.error,
      recovering: state.recovering,
      ready: state.trial != nil and ready?(state.observed, state.trial.network)
    }
  end

  defp publish(state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "network", {:network, public(state)})
    state
  end

  defp schedule_poll(state), do: Process.send_after(self(), :poll, state.poll_ms)
  defp now, do: System.monotonic_time(:millisecond)
end
