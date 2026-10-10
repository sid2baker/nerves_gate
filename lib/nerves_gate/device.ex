defmodule NervesGate.Device do
  @moduledoc """
  Shared CQRS interface for LiveView, IEx/SSH and future client adapters.

  Subscribe **before** reading `projection/1`; notifications are
  `{:device, projection}`. `version` identifies the schema and `revision` is an
  opaque equality token, valid only for this gateway incarnation. Notifications
  are snapshots, not a durable event stream. Re-read after reconnecting.

  `dispatch/3` accepts a string action ID and string-keyed parameters. Both
  success and rejection include the current projection. `:expected_revision`
  optionally rejects stale clients. Availability is advisory, not authorization;
  commands are revalidated and the network executor enforces its own safeguards.

  There is no durable command queue or exactly-once promise. On a lost reply,
  query the projection before retrying. Confirmation/cancellation always require
  the explicit trial ID, so an old command cannot affect a newer trial.
  """
  use GenServer
  alias NervesGate.Network
  alias NervesGate.Device.{Error, Workflow}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def projection(server \\ __MODULE__), do: GenServer.call(server, :projection)

  @doc "Projection topic for lifecycle-managed subscribers such as LiveView.subscribe/3."
  def topic(server \\ __MODULE__), do: GenServer.call(server, :topic)

  def subscribe(server \\ __MODULE__) do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, topic(server))
  end

  @doc "Returns `{:ok, %{result: map, projection: map}}` or `{:error, %{error: map, projection: map}}`."
  def dispatch(action, params \\ %{}, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    command = %{action: action, params: params}
    access = Keyword.get(opts, :access)

    GenServer.call(
      server,
      {:dispatch, command, Keyword.get(opts, :expected_revision), access},
      20_000
    )
  end

  @impl true
  def init(opts) do
    Network.subscribe()
    NervesGate.Remote.subscribe()

    state = %{
      network: Keyword.get(opts, :network, Network),
      remote: Keyword.get(opts, :remote, NervesGate.Remote),
      remote_status: nil,
      topic: Keyword.get(opts, :topic, "device"),
      workflow: Workflow.new(),
      epoch: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      sequence: 0,
      status: nil,
      projection: nil
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, refresh(state)}

  @impl true
  def handle_call(:topic, _from, state), do: {:reply, state.topic, state}

  def handle_call(:projection, _from, state) do
    state = refresh(state)
    {:reply, state.projection, state}
  end

  def handle_call({:dispatch, command, expected, access}, _from, state) do
    state = refresh(state)

    result =
      cond do
        expected != nil and expected != state.projection.revision ->
          {:error, Error.from(:stale_revision)}

        not is_binary(command.action) ->
          {:error, Error.new("unknown_action", "Action IDs must be strings.")}

        not json_value?(command.params) ->
          {:error, Error.new("invalid_parameters", "Parameters must contain only JSON values.")}

        true ->
          %{decision: decision} =
            NervesGate.Device.Workflow.evaluate(
              state.workflow,
              state.status,
              command,
              state.remote_status
            )

          execute(decision, state, access)
      end

    state = refresh(state)

    reply =
      case result do
        {:ok, value} -> {:ok, %{result: value, projection: state.projection}}
        {:error, error} -> {:error, %{error: error, projection: state.projection}}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:remote_changed, state) do
    {:noreply, refresh(state)}
  end

  def handle_info({:network, _snapshot}, state) do
    {:noreply, refresh(state)}
  end

  defp execute({:result, result}, _network, _access), do: {:ok, result}
  defp execute({:error, error}, _network, _access), do: {:error, error}

  defp execute({:effect, {:remote, :login_url, _}}, %{remote: remote}, _) do
    {:ok, %{url: NervesGate.Remote.login_url(remote)}}
  catch
    :exit, _ -> {:error, Error.new("remote_unavailable", "Tailscale is unavailable.")}
  end

  defp execute({:effect, {:remote, action, params}}, %{remote: remote}, _) do
    case NervesGate.Remote.command(action, params, remote) do
      :ok -> {:ok, %{accepted: true}}
      {:error, error} -> {:error, error}
    end
  catch
    :exit, _ -> {:error, Error.from(:outcome_unknown)}
  end

  defp execute({:effect, {action, value}}, %{network: network}, access) do
    result =
      case action do
        :propose -> NervesGate.Network.propose(value, network, access)
        :confirm -> NervesGate.Network.confirm(value, network)
        :cancel -> NervesGate.Network.cancel(value, network)
      end

    case result do
      :ok -> {:ok, %{}}
      {:ok, id} -> {:ok, %{trial_id: id}}
      {:error, reason} -> {:error, NervesGate.Device.Error.from(reason)}
    end
  catch
    :exit, _ -> {:error, NervesGate.Device.Error.from(:outcome_unknown)}
  end

  # Fail closed if a graph change ever stops producing a decision.
  defp execute(_, _, _),
    do: {:error, Error.new("decision_failed", "No device decision was produced.")}

  defp refresh(state) do
    status = network_status(state.network)
    remote = remote_status(state.remote)

    if state.projection != nil and status == state.status and remote == state.remote_status do
      state
    else
      %{projection: projection} = Workflow.evaluate(state.workflow, status, nil, remote)
      sequence = state.sequence + 1
      projection = Map.put(projection, :revision, "#{state.epoch}:#{sequence}")
      Phoenix.PubSub.broadcast(NervesGate.PubSub, state.topic, {:device, projection})
      %{state | status: status, remote_status: remote, projection: projection, sequence: sequence}
    end
  end

  defp remote_status(remote) do
    NervesGate.Remote.status(remote)
  catch
    :exit, _ -> NervesGate.Remote.unavailable()
  end

  defp network_status(network) do
    status = Network.status(network)
    # Adapter errors can contain exceptions, refs or PIDs. Never pass those (or
    # raw configuration file contents in decode errors) into a portable fact.
    %{status | error: status.error && Error.from(status.error)}
  catch
    :exit, _ -> nil
  end

  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json_value?([]) do
    true
  end

  defp json_value?([head | tail]) do
    json_value?(head) and is_list(tail) and json_value?(tail)
  end

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and json_value?(item)
      end)

  defp json_value?(_), do: false
end
