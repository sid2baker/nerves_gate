defmodule NervesGate.DeviceState do
  @moduledoc """
  Public snapshot/operation API for canonical gateway state.

  State owners synchronously publish secret-free reports. Consumers atomically
  subscribe to one snapshot followed by future ordered operations.
  """

  alias NervesGate.DeviceState.{Public, Server, State}

  @type report :: State.report()
  @type snapshot :: Server.snapshot()

  @spec publish(report(), GenServer.server()) :: :ok | {:error, term()}
  def publish(report, server \\ Server) do
    GenServer.call(server, {:publish, report})
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

  @spec unsubscribe(Server.subscriber(), GenServer.server()) :: :ok
  def unsubscribe(subscriber \\ self(), server \\ Server),
    do: Server.unsubscribe(subscriber, server)

  @doc "Returns whether a value can cross the shared public-state boundary."
  @spec public?(term()) :: boolean()
  defdelegate public?(value), to: Public
end
