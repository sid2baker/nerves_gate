defmodule NervesGate.Network.Effect do
  @moduledoc "Post-commit request to the independently supervised trial safety runtime."
  use Jido.Agent.Directive

  @schema Zoi.struct(
            __MODULE__,
            %{
              operation:
                Zoi.enum([:propose, :confirm, :cancel, :auto_confirm, :auto_cancel, :await]),
              id: Zoi.string(),
              network: Zoi.any() |> Zoi.default(nil)
            },
            coerce: true
          )
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  def schema, do: @schema
end
