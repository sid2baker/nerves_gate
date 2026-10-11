defmodule NervesGate.Connectivity.Effect do
  @moduledoc "A bounded, read-only recheck or cancellation; never a network mutation."
  use Jido.Agent.Directive

  @schema Zoi.struct(
            __MODULE__,
            %{
              operation: Zoi.enum([:recheck, :cancel]),
              outage: Zoi.integer() |> Zoi.nullable() |> Zoi.default(nil),
              attempt:
                Zoi.integer() |> Zoi.min(1) |> Zoi.max(3) |> Zoi.nullable() |> Zoi.default(nil)
            },
            coerce: true
          )
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  def schema, do: @schema
end
