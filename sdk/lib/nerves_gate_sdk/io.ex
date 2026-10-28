defmodule NervesGateSDK.IO do
  @moduledoc """
  Inputs describe observable state; outputs describe repeatable desired state.
  Calls preserve the actual managed plugin process as registrar, handler or writer.
  Registration/publication use local IDs; observation and writer calls use full IDs.

  Subscribe before reading inputs and monitor the returned controller PID. Subscribe
  afresh after controller loss. `{:nerves_gate_input_changed, full_id}` and
  `{:nerves_gate_output_changed, local_id}` are coalesced hints: read the input or
  desired value to consume the hint. Periodically check freshness too.
  A handler must re-register after controller loss; old desires never survive it.

  Desired values and observations are runtime-only. Feedback is an ordinary input,
  not proof of a command's completion. This is not a safety or real-time interface.
  """
  @type value :: boolean() | integer() | float() | String.t()
  @type value_type :: :boolean | :integer | :float | :string

  alias NervesGateSDK.Backend

  @doc "Persist and bind an input to the calling process."
  def register_input(definition), do: Backend.call(:io_register_input, [definition])

  @doc "Persist and bind an output to a handler in this activation."
  def register_output(definition, handler),
    do: Backend.call(:io_register_output, [definition, handler])

  @doc "Publish latest state; invalid/unknown quality requires a nil value."
  def publish_input(id, value, quality \\ :good),
    do: Backend.call(:io_publish_input, [id, value, quality])

  @doc "Read the handler's current desire. nil means no target; false is a target."
  def read_desired(id), do: Backend.call(:io_read_desired, [id])

  def input(id), do: Backend.call(:io_input, [id])
  def output(id), do: Backend.call(:io_output, [id])
  def subscribe(id), do: Backend.call(:io_subscribe, [id])
  def unsubscribe(id), do: Backend.call(:io_unsubscribe, [id])

  @doc "Exclusively claim an output without establishing a desired value."
  def claim_output(id), do: Backend.call(:io_claim_output, [id])

  @doc "Store desired state only; success does not indicate physical success."
  def set_output(id, value), do: Backend.call(:io_set_output, [id, value])

  @doc "Release ownership and desire without changing physical equipment."
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

  defmodule OutputDefinition do
    @moduledoc "A repeatable desired-state setter. Feedback, if supplied, names a local input."
    @enforce_keys [:id, :type]
    defstruct [:id, :type, :unit, :min, :max, :feedback_input_id]

    @type t :: %__MODULE__{
            id: String.t(),
            type: NervesGateSDK.IO.value_type(),
            unit: String.t() | nil,
            min: number() | nil,
            max: number() | nil,
            feedback_input_id: String.t() | nil
          }
  end

  defmodule Observation do
    @moduledoc "Latest platform receipt of input state. UTC is nil until the clock synchronizes."
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
