defmodule NervesGate.Remote.Effect do
  @moduledoc "Transient post-commit daemon command or private cached query."
  use Jido.Agent.Directive

  @schema Zoi.struct(
            __MODULE__,
            %{
              operation: Zoi.enum([:connect, :configure, :disconnect, :login_url]),
              id: Zoi.any() |> Zoi.default(nil),
              params: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  def schema, do: @schema
end
