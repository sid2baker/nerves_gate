defmodule NervesGate.Network do
  @moduledoc """
  LAN executor. First setup over verified USB auto-saves; other changes have a
  browser-independent, 60-second rollback deadline.
  Client adapters should use `NervesGate.Device`, not these low-level commands.
  """
  use GenServer
  alias NervesGate.{Config, Network}

  @callback apply_config(map(), term()) :: :ok | {:error, term()}
  @callback snapshot(term()) :: map()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def propose(network, server \\ __MODULE__, access \\ nil),
    do: GenServer.call(server, {:propose, network, access}, 15_000)

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

  def handle_call({:propose, _, _}, _from, %{config: nil} = state),
    do: {:reply, {:error, :invalid_saved_config}, state}

  def handle_call({:propose, _, _}, _from, %{trial: trial} = state) when not is_nil(trial),
    do: {:reply, {:error, :trial_in_progress}, state}

  def handle_call({:propose, _, _}, _from, %{recovering: true} = state),
    do: {:reply, {:error, :recovery_in_progress}, state}

  def handle_call({:propose, network, access}, _from, state) do
    with {:ok, network} <- Config.validate_network(network),
         # Make even first-run defaults durable BEFORE touching an interface.
         :ok <- Config.save(state.config, state.path) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      state = refresh(state)

      auto_save =
        not state.config["setup_completed"] and Network.Access.usb?(state.observed, access)

      timeout = if auto_save, do: 15_000, else: state.trial_ms
      timer = Process.send_after(self(), {:expire, id}, timeout)

      trial = %{
        auto_save: auto_save,
        id: id,
        network: network,
        deadline: now() + timeout,
        expires_at: System.system_time(:millisecond) + timeout,
        timer: timer
      }

      state = %{state | trial: trial, error: nil}

      case apply_network(state, network) do
        :ok ->
          state = maybe_save(refresh(state))
          result = trial_result(state.error, id)
          {:reply, result, publish(state)}

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
    next = maybe_save(refresh(next))
    if public(next) != public(state), do: publish(next)
    schedule_poll(next)
    {:noreply, next}
  end

  defp maybe_save(%{trial: %{auto_save: true} = trial} = state) do
    cond do
      now() >= trial.deadline ->
        rollback(state, :expired)

      ready?(state.observed, trial.network) ->
        config = %{state.config | "network" => trial.network, "setup_completed" => true}

        case Config.save(config, state.path) do
          :ok ->
            Process.cancel_timer(trial.timer)
            %{state | config: config, trial: nil, error: nil}

          {:error, reason} ->
            rollback(state, {:save, reason})
        end

      conflicts(state.observed, trial.network) != [] ->
        rollback(state, :conflicting_networks)

      true ->
        state
    end
  end

  defp maybe_save(state) do
    state
  end

  defp trial_result(nil, id), do: {:ok, id}
  defp trial_result(error, _), do: {:error, error}

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

  @doc "Configuration readiness only. USB access, Internet and remote equipment reachability are separate."
  def ready?(observed, %{"mode" => "ethernet"} = network) when is_map(observed) do
    internet = Enum.find(observed.ports, &(&1.name == network["internet_port"]))
    equipment = Enum.find(observed.ports, &(&1.name == Config.equipment_port(network)))

    internet != nil and equipment != nil and
      Enum.all?(
        [internet, equipment],
        &(&1.present and &1.master == nil and &1.state == :configured)
      ) and
      internet.method == "dhcp" and equipment.method == "static" and
      address_matches?(equipment.addresses, network["equipment"]) and
      conflicts(observed, network) == []
  end

  def ready?(
        %{bridge: bridge, ports: ports} = observed,
        %{"mode" => "shared", "equipment" => network} = settings
      ) do
    bridge.present and bridge.state == :configured and
      bridge.method == network["ip_method"] and
      Enum.all?(ports, &(not &1.present or &1.master == "br0")) and
      (network["ip_method"] == "dhcp" or address_matches?(bridge.addresses, network)) and
      conflicts(observed, settings) == []
  end

  def ready?(%{ports: ports} = observed, %{"mode" => "ports"} = network) do
    Enum.all?(Config.ports(network), fn {name, setting} ->
      port_ready?(Enum.find(ports, &(&1.name == name)), setting)
    end) and conflicts(observed, network) == []
  end

  def ready?(_, _), do: false

  defp port_ready?(nil, setting) do
    is_nil(setting)
  end

  defp port_ready?(%{present: false}, setting) do
    is_nil(setting)
  end

  defp port_ready?(port, nil) do
    configured_port?(port) and port.method == "disabled"
  end

  defp port_ready?(port, %{"address" => address}) do
    configured_port?(port) and port.method == address["ip_method"] and
      (port.method == "dhcp" or address_matches?(port.addresses, address))
  end

  defp configured_port?(port) do
    port.state == :configured and is_nil(port.master)
  end

  defp address_matches?(addresses, network) do
    Enum.any?(addresses, fn %{address: address, prefix_length: prefix} ->
      case network["ip_method"] do
        "dhcp" ->
          match?({:ok, {a, _, _, _}} when a > 0 and a < 224 and a != 127, Config.ipv4(address))

        "static" ->
          address == network["static_ip"] and
            Config.prefix_length(network["subnet_mask"]) == {:ok, prefix}
      end
    end)
  end

  @doc "Observed overlaps block confirmation; USB's derived subnet is checked too."
  def conflicts(%{ports: ports, bridge: bridge} = observed, network) do
    networks = if network["mode"] == "shared", do: [bridge], else: ports
    usb = Map.get(observed, :usb, %{addresses: []})

    pairs =
      for {left, i} <- Enum.with_index(networks ++ [usb]),
          {right, j} <- Enum.with_index(networks ++ [usb]),
          i < j,
          a <- Map.get(left, :addresses, []),
          b <- Map.get(right, :addresses, []),
          Config.overlap?(a.address, a.prefix_length, b.address, b.prefix_length),
          do: {i, j}

    if pairs == [],
      do: [],
      else: [
        "Network addresses overlap. Use different Internet, equipment and USB subnets before continuing."
      ]
  end

  def conflicts(_, _), do: []

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
