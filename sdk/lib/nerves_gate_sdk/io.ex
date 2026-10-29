defmodule NervesGateSDK.IO do
  @moduledoc """
  Readings describe observed state; outputs hold the Desire of their current controller.
  Calls preserve the actual managed plugin process as registrar, reader or writer.

  Plugins register inputs and `publish/3` Readings using local IDs. Output handling
  belongs to `NervesGateSDK.Output`, which hides hints, Desires and claim epochs.
  Readers and writers use full IDs.

  Subscribe before reading inputs and monitor the returned controller PID. Subscribe
  afresh after controller loss. `{:nerves_gate_input_changed, full_id}` is a
  coalesced hint: read the input to consume it. Periodically check freshness too.

  Readings and Desires are runtime-only. Storing a Desire is not device success;
  an output's Status interprets Apply outcomes and declared evidence. This is not a
  safety or real-time interface.
  """
  @type value :: boolean() | integer() | float() | String.t()
  @type value_type :: :boolean | :integer | :float | :string

  alias NervesGateSDK.Backend

  @doc "Persist and bind an input to the calling process."
  def register_input(definition), do: Backend.call(:io_register_input, [definition])

  @doc "Publish the latest Reading; invalid/unknown quality requires a nil value."
  def publish(id, value, quality \\ :good), do: Backend.call(:io_publish, [id, value, quality])

  @doc "Read an input's availability, latest Reading and freshness. Consumes this caller's hint."
  def input(id), do: Backend.call(:io_input, [id])

  @doc "Read an output's availability, Authority relative to the caller, Desire and Status."
  def output(id), do: Backend.call(:io_output, [id])

  def subscribe(id), do: Backend.call(:io_subscribe, [id])
  def unsubscribe(id), do: Backend.call(:io_unsubscribe, [id])

  @doc "Exclusively claim an output without establishing a Desire."
  def claim_output(id), do: Backend.call(:io_claim_output, [id])

  @doc "Store a Desire only; success does not indicate physical success."
  def set_output(id, value), do: Backend.call(:io_set_output, [id, value])

  @doc "Release Authority and Desire. The plugin's declared release behaviour applies."
  def release_output(id), do: Backend.call(:io_release_output, [id])

  defmodule InputDefinition do
    @moduledoc "A plugin-local observable state definition, persisted by the platform."
    @enforce_keys [:id, :type]
    defstruct [:id, :type, :unit, :expected_interval_ms]

    @type t :: %__MODULE__{
            id: String.t(),
            type: NervesGateSDK.IO.value_type(),
            unit: String.t() | nil,
            expected_interval_ms: pos_integer() | nil
          }
  end

  defmodule Evidence do
    @moduledoc """
    One input that indicates whether an output's Desire was achieved.

    `input` is a full input ID and may belong to another plugin. Only good Readings
    received at least `settle_ms` after the Desire changed count. Stronger roles win:
    `:physical`, then `:consequence`, `:estimate` and `:readback`.

    `expect` is `:equals`, `{:tolerance, delta}` for numeric outputs, or for boolean
    outputs a map from Desire to `{:above, number}`, `{:below, number}` or
    `{:equals, value}`.
    """
    @enforce_keys [:input, :role]
    defstruct [:input, :role, settle_ms: 0, expect: :equals]

    @type condition ::
            {:above, number()} | {:below, number()} | {:equals, NervesGateSDK.IO.value()}
    @type t :: %__MODULE__{
            input: String.t(),
            role: :readback | :physical | :consequence | :estimate,
            settle_ms: non_neg_integer(),
            expect: :equals | {:tolerance, number()} | %{boolean() => condition()}
          }
  end

  defmodule OutputDefinition do
    @moduledoc """
    A repeatable desired-state setter. `evidence` lists inputs used for Status.
    `on_release` describes, for operators, what the plugin does when the Desire
    ends: `:hold` or `{:value, value}`. The platform never performs it.
    """
    @enforce_keys [:id, :type]
    defstruct [:id, :type, :unit, :min, :max, :on_release, evidence: []]

    @type t :: %__MODULE__{
            id: String.t(),
            type: NervesGateSDK.IO.value_type(),
            unit: String.t() | nil,
            min: number() | nil,
            max: number() | nil,
            on_release: :hold | {:value, NervesGateSDK.IO.value()} | nil,
            evidence: [NervesGateSDK.IO.Evidence.t()]
          }
  end

  defmodule Reading do
    @moduledoc "Latest platform receipt of an input's state. UTC is nil until the clock synchronizes."
    @enforce_keys [:input_id, :value, :quality, :received_at_ms]
    defstruct [:input_id, :value, :quality, :received_at_ms, :received_at_utc]

    @type t :: %__MODULE__{
            input_id: String.t(),
            value: NervesGateSDK.IO.value() | nil,
            quality: :good | :invalid | :unknown,
            received_at_ms: integer(),
            received_at_utc: DateTime.t() | nil
          }
  end
end
