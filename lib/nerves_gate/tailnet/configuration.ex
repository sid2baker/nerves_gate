defmodule NervesGate.Tailnet.Configuration do
  @moduledoc "Owns guarded Tailscale profile changes and profile-specific rollback."

  use GenServer

  alias NervesGate.Settings.ChangeControl
  alias NervesGate.Tailscale

  @default_confirmation_timeout :timer.minutes(5)

  defstruct [
    :pending,
    :timer,
    :change_control,
    :ops,
    confirmation_timeout: @default_confirmation_timeout
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec stage(String.t(), String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def stage(auth_token, connection_id, server \\ __MODULE__)

  def stage(auth_token, connection_id, server)
      when is_binary(auth_token) and byte_size(auth_token) in 8..512 and
             is_binary(connection_id) do
    GenServer.call(server, {:stage, fn -> auth_token end, connection_id}, 30_000)
  end

  def stage(_auth_token, _connection_id, _server), do: {:error, :invalid_auth_token}

  @spec confirm(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def confirm(change_id, connection_id, server \\ __MODULE__) do
    GenServer.call(server, {:confirm, change_id, connection_id}, 20_000)
  end

  @spec revert(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def revert(change_id, server \\ __MODULE__) do
    GenServer.call(server, {:revert, change_id}, 20_000)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    state = %__MODULE__{
      change_control: Keyword.get(options, :change_control, ChangeControl),
      ops: Keyword.get(options, :ops, default_ops()),
      confirmation_timeout:
        Keyword.get(
          options,
          :confirmation_timeout,
          Application.get_env(
            :nerves_gate,
            :settings_confirmation_timeout,
            @default_confirmation_timeout
          )
        )
    }

    if state.change_control.active(:tailnet), do: send(self(), :recover_unconfirmed_change)
    {:ok, state}
  end

  @impl true
  def handle_call({:stage, _load_token, _connection_id}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :candidate_in_progress}, state}
  end

  def handle_call({:stage, load_token, connection_id}, _from, state) do
    with {:ok, previous_profile_id} <- state.ops.current_profile.(),
         id = change_id(),
         rollback = %{"previous_profile_id" => previous_profile_id},
         :ok <-
           state.change_control.begin_change(
             :tailnet,
             id,
             self(),
             connection_id,
             rollback
           ) do
      case state.ops.stage.(load_token.(), id, previous_profile_id) do
        {:ok, rollback} ->
          :ok =
            state.change_control.awaiting_confirmation(
              id,
              rollback,
              state.confirmation_timeout
            )

          timer =
            Process.send_after(self(), {:confirmation_timeout, id}, state.confirmation_timeout)

          pending = %{
            id: id,
            rollback: rollback,
            source_connection: connection_id,
            confirmation_deadline:
              System.monotonic_time(:millisecond) + state.confirmation_timeout
          }

          {:reply, {:ok, public_pending(pending)}, %{state | pending: pending, timer: timer}}

        {:error, reason, candidate_rollback} ->
          state.ops.rollback.(candidate_rollback)
          :ok = state.change_control.finish(id, reason)
          {:reply, {:error, reason}, state}

        {:error, reason} ->
          state.ops.rollback.(rollback)
          :ok = state.change_control.finish(id, reason)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:confirm, id, connection_id}, _from, %{pending: %{id: id}} = state) do
    if state.pending.source_connection == connection_id do
      {:reply, {:error, :fresh_connection_required}, state}
    else
      case state.ops.commit.(state.pending.rollback) do
        :ok ->
          cancel_timer(state)
          :ok = state.change_control.finish(id)
          {:reply, :ok, %{state | pending: nil, timer: nil}}

        {:error, reason} ->
          state = rollback(state, reason)
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:confirm, _id, _connection_id}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call({:revert, id}, _from, %{pending: %{id: id}} = state) do
    {:reply, :ok, rollback(state, :reverted)}
  end

  def handle_call({:revert, _id}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{pending: if(state.pending, do: public_pending(state.pending))}, state}
  end

  @impl true
  def handle_info({:confirmation_timeout, id}, %{pending: %{id: id}} = state) do
    {:noreply, rollback(state, :confirmation_timeout)}
  end

  def handle_info({:confirmation_timeout, _id}, state), do: {:noreply, state}

  def handle_info(:recover_unconfirmed_change, state) do
    case state.change_control.active(:tailnet) do
      %{id: id, rollback: rollback} ->
        state.ops.rollback.(rollback)
        :ok = state.change_control.finish(id, :recovered_unconfirmed_change)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp rollback(state, reason) do
    cancel_timer(state)
    :ok = state.change_control.rolling_back(state.pending.id)
    result = state.ops.rollback.(state.pending.rollback)
    :ok = state.change_control.finish(state.pending.id, rollback_result(reason, result))
    %{state | pending: nil, timer: nil}
  end

  defp rollback_result(reason, :ok), do: reason
  defp rollback_result(_reason, {:error, rollback_reason}), do: rollback_reason

  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(state), do: Process.cancel_timer(state.timer)

  defp public_pending(pending) do
    %{
      id: pending.id,
      phase: :awaiting_confirmation,
      remaining_seconds:
        max(
          0,
          div(pending.confirmation_deadline - System.monotonic_time(:millisecond) + 999, 1_000)
        )
    }
  end

  defp change_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp default_ops do
    %{
      current_profile: &Tailscale.current_profile_id/0,
      stage: &Tailscale.stage_enrollment/3,
      commit: &Tailscale.commit_enrollment/1,
      rollback: &Tailscale.rollback_enrollment/1
    }
  end
end
