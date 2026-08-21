defmodule NervesGate.DeviceState.Replica do
  @moduledoc "A remote public snapshot plus local transport freshness metadata."

  alias NervesGate.DeviceState.Public
  alias NervesGate.DeviceState.Snapshot

  @enforce_keys [:node, :data, :boot_id, :revision]
  defstruct [:node, :data, :boot_id, :revision, :last_seen_at, connected: false]

  @type t :: %__MODULE__{
          node: node(),
          data: Public.t(),
          boot_id: String.t(),
          revision: non_neg_integer(),
          connected: boolean(),
          last_seen_at: DateTime.t() | nil
        }

  @spec new(node(), Snapshot.t()) :: t()
  def new(node, %Snapshot{} = snapshot) when is_atom(node) do
    %__MODULE__{
      node: node,
      data: snapshot.data,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      connected: true,
      last_seen_at: now()
    }
  end

  @spec apply_operation(t(), String.t(), non_neg_integer(), Public.operation()) ::
          {:ok, t()} | :duplicate | :resync
  def apply_operation(
        %__MODULE__{boot_id: boot_id, revision: current} = replica,
        boot_id,
        revision,
        operation
      )
      when revision == current + 1 do
    {:ok,
     %{
       replica
       | data: Public.reduce(replica.data, operation),
         revision: revision,
         connected: true,
         last_seen_at: now()
     }}
  end

  def apply_operation(
        %__MODULE__{boot_id: boot_id, revision: current},
        boot_id,
        revision,
        _operation
      )
      when revision <= current,
      do: :duplicate

  def apply_operation(%__MODULE__{}, _boot_id, _revision, _operation), do: :resync

  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = replica), do: %{replica | connected: false}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
end
