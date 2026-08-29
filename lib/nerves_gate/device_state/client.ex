defmodule NervesGate.DeviceState.Client do
  @moduledoc """
  Pure reducer for one revisioned DeviceState stream.

  A client atomically installs a snapshot and then accepts only operations from
  the same server boot in strict revision order. Duplicate operations are
  ignored. A boot change or revision gap requests a fresh snapshot; operations
  are never buffered.
  """

  alias NervesGate.DeviceState.State

  @enforce_keys [:node, :boot_id, :revision, :state, :hydrated]
  defstruct [:node, :boot_id, :revision, :state, :hydrated]

  @type t :: %__MODULE__{
          node: node(),
          boot_id: String.t(),
          revision: non_neg_integer(),
          state: State.t(),
          hydrated: boolean()
        }

  @type result :: {:ok, t(), :changed | :duplicate} | :resync

  @spec install(map()) :: {:ok, t()} | :error
  def install(%{
        node: node,
        boot_id: boot_id,
        revision: revision,
        state: %State{} = state,
        hydrated: hydrated
      })
      when is_atom(node) and is_binary(boot_id) and is_integer(revision) and revision >= 0 and
             is_boolean(hydrated) do
    {:ok,
     %__MODULE__{
       node: node,
       boot_id: boot_id,
       revision: revision,
       state: state,
       hydrated: hydrated
     }}
  end

  def install(_snapshot), do: :error

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = client), do: Map.from_struct(client)

  @spec reduce(t(), term()) :: result()
  def reduce(
        %__MODULE__{node: node, boot_id: boot_id, revision: previous} = client,
        {:device_state_operation, node, boot_id, revision, operation}
      )
      when revision == previous + 1 do
    case State.reduce(client.state, operation) do
      {:ok, state} ->
        {:ok,
         %{
           client
           | state: state,
             revision: revision,
             hydrated: State.hydrated?(state)
         }, :changed}

      :error ->
        :resync
    end
  end

  def reduce(
        %__MODULE__{node: node, boot_id: boot_id, revision: current} = client,
        {:device_state_operation, node, boot_id, revision, _operation}
      )
      when revision <= current,
      do: {:ok, client, :duplicate}

  def reduce(%__MODULE__{}, {:device_state_operation, _node, _boot_id, _revision, _operation}),
    do: :resync

  def reduce(%__MODULE__{}, _message), do: :resync

  @spec heartbeat(t(), term()) :: {:ok, t()} | :resync
  def heartbeat(
        %__MODULE__{node: node, boot_id: boot_id, revision: revision} = client,
        {:device_state_heartbeat, node, boot_id, remote_revision}
      )
      when remote_revision <= revision,
      do: {:ok, client}

  def heartbeat(%__MODULE__{}, {:device_state_heartbeat, _node, _boot_id, _revision}),
    do: :resync

  def heartbeat(%__MODULE__{}, _message), do: :resync
end
