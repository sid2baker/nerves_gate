defmodule ModbusPlugin.Endpoint do
  @moduledoc """
  Platform endpoints for one connection's mappings. Inputs are registered and
  published by the runtime process that owns the transport, so the platform binds
  that actual PID and clears all runtime state when it stops. Outputs are handled
  by the connection's `NervesGateSDK.Output` runtime (`ModbusPlugin.Outputs`).
  Holding registers are integers 0..65535; coils are booleans.
  """
  alias NervesGateSDK.IO, as: SDKIO
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition}

  def id(config, %{id: mapping_id}), do: "#{config.id}.#{mapping_id}"
  def full_id(config, mapping), do: "modbus_plugin." <> id(config, mapping)

  @doc "Register every input mapping, in order; the first failure stops before any transport opens."
  def register(config) do
    config.mappings
    |> Enum.reject(&(&1.direction == :output))
    |> Enum.reduce_while(:ok, fn mapping, :ok ->
      case SDKIO.register_input(%InputDefinition{
             id: id(config, mapping),
             type: type(mapping.table),
             expected_interval_ms: if(config.role == :client, do: config.interval)
           }) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:registration_failed, mapping.id, reason}}}
      end
    end)
  end

  @doc """
  Output definitions. A linked feedback input is readback evidence: it shows the
  register/coil value, not a physical equipment condition. A released output keeps
  its last written value.
  """
  def outputs(config) do
    for %{direction: :output} = mapping <- config.mappings do
      %OutputDefinition{
        id: id(config, mapping),
        type: type(mapping.table),
        min: if(mapping.table == :holding, do: 0),
        max: if(mapping.table == :holding, do: 65535),
        on_release: :hold,
        evidence:
          if(mapping.feedback,
            do: [%Evidence{input: full_id(config, %{id: mapping.feedback}), role: :readback}],
            else: []
          )
      }
    end
  end

  def publish(config, mapping, value, quality \\ :good),
    do: SDKIO.publish(id(config, mapping), value, quality)

  def type(:coil), do: :boolean
  def type(:holding), do: :integer
end
