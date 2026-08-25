defmodule NervesGate.DeviceState do
  @moduledoc """
  Public snapshot/event API for canonical gateway state.

  State owners synchronously publish secret-free events. Consumers atomically
  subscribe to one snapshot followed by future ordered events.
  """

  alias NervesGate.DeviceState.{Server, State}
  alias NervesGate.Secret

  @type event :: State.event()
  @type snapshot :: Server.snapshot()

  @spec publish(event(), GenServer.server()) :: :ok | {:error, term()}
  def publish(event, server \\ Server) do
    GenServer.call(server, {:publish, event})
  catch
    :exit, {:noproc, _details} -> {:error, :shutting_down}
    :exit, {:normal, _details} -> {:error, :shutting_down}
    :exit, {:shutdown, _details} -> {:error, :shutting_down}
  end

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ Server), do: Server.snapshot(server)

  @spec state(GenServer.server()) :: State.t()
  def state(server \\ Server), do: Server.state(server)

  @spec subscribe(Server.subscriber(), GenServer.server()) :: {:ok, snapshot()}
  def subscribe(subscriber \\ self(), server \\ Server),
    do: Server.subscribe(subscriber, server)

  @doc "Returns whether a value can cross the shared public-state boundary."
  @spec public?(term()) :: boolean()
  def public?(%Secret{}), do: false
  def public?(value) when is_pid(value) or is_port(value) or is_reference(value), do: false
  def public?(value) when is_function(value), do: false
  def public?(value) when is_binary(value) or is_number(value) or is_atom(value), do: true

  def public?(value) when is_list(value), do: Enum.all?(value, &public?/1)

  def public?(%_module{} = value) do
    value
    |> Map.from_struct()
    |> public?()
  end

  def public?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} -> public_key?(key) and public?(item) end)
  end

  # IPv4 addresses are accepted temporarily as Erlang-native public values and
  # are encoded as strings at HTTP boundaries. No other tuple is public.
  def public?({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: true

  def public?(_value), do: false

  defp public_key?(key) when is_atom(key) or is_binary(key), do: true
  defp public_key?(_key), do: false
end
