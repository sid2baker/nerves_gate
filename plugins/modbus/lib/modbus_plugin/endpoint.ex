defmodule ModbusPlugin.Endpoint do
  @moduledoc """
  Platform endpoint registration and publication for one connection's mappings.
  Called only from the runtime process that owns the transport, so the platform
  binds that actual PID as registrar and handler and clears all runtime state
  when it stops. Holding registers are integers 0..65535; coils are booleans.
  """
  alias NervesGateSDK.IO, as: SDKIO
  alias NervesGateSDK.IO.{InputDefinition, OutputDefinition}

  def id(config, %{id: mapping_id}), do: "#{config.id}.#{mapping_id}"
  def full_id(config, mapping), do: "modbus_plugin." <> id(config, mapping)

  @doc "Register every mapping, in order; the first failure stops before any transport opens."
  def register(config, handler) do
    Enum.reduce_while(config.mappings, :ok, fn mapping, :ok ->
      case register_mapping(config, mapping, handler) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:registration_failed, mapping.id, reason}}}
      end
    end)
  end

  defp register_mapping(config, %{direction: :output} = mapping, handler) do
    SDKIO.register_output(
      %OutputDefinition{
        id: id(config, mapping),
        type: type(mapping.table),
        min: if(mapping.table == :holding, do: 0),
        max: if(mapping.table == :holding, do: 65535),
        feedback_input_id: if(mapping.feedback, do: id(config, %{id: mapping.feedback}))
      },
      handler
    )
  end

  defp register_mapping(config, mapping, _) do
    SDKIO.register_input(%InputDefinition{
      id: id(config, mapping),
      type: type(mapping.table),
      expected_interval_ms: if(config.role == :client, do: config.interval)
    })
  end

  def publish(config, mapping, value, quality \\ :good),
    do: SDKIO.publish_input(id(config, mapping), value, quality)

  def type(:coil), do: :boolean
  def type(:holding), do: :integer
end
