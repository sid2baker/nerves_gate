defmodule NervesGate.IO.Manual do
  @moduledoc """
  The gateway's manual writer. This one supervised process owns manual claims, so
  they outlive any browser tab and any operator can release them. It keeps no state:
  ownership is read back from `NervesGate.IO`, which applies the same exclusive-writer
  validation as for automations and clears manual claims on plugin/binding loss or
  an I/O restart.

  A successful `set/2` stores a Desire only; the plugin decides how and whether the
  equipment follows, and Status reports what the evidence says. `release/1` clears
  the Desire; the plugin's declared release behaviour applies.
  """
  use GenServer
  alias NervesGate.Error
  alias NervesGate.IO, as: GateIO

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Every endpoint's snapshot. Output `owned?` means manual control holds it."
  def status, do: Error.protect(fn -> GenServer.call(__MODULE__, :status) end)

  @doc "Take manual control of a free, available output without setting a value."
  def claim(id), do: Error.protect(fn -> GenServer.call(__MODULE__, {:claim, id}) end)

  @doc "Store a validated desired value for a manually controlled output."
  def set(id, value), do: Error.protect(fn -> GenServer.call(__MODULE__, {:set, id, value}) end)

  @doc "Clear manual desire and ownership. Does not revert or stop the equipment."
  def release(id), do: Error.protect(fn -> GenServer.call(__MODULE__, {:release, id}) end)

  @impl true
  def init(_), do: {:ok, nil}

  # Every I/O call runs in this process, which is the claim owner. A lost I/O
  # reply must not crash it: that would silently drop every manual claim.
  @impl true
  def handle_call(:status, _, state) do
    reply =
      case Error.protect(&GateIO.snapshot/0) do
        {:error, :io_catalog_unavailable} -> {:error, error(:io_catalog_unavailable)}
        result -> result
      end

    {:reply, reply, state}
  end

  def handle_call({:claim, id}, _, state),
    do: {:reply, result(Error.protect(fn -> GateIO.claim_output(id) end)), state}

  def handle_call({:set, id, value}, _, state) do
    reply =
      case Error.protect(fn -> GateIO.output(id) end) do
        {:ok, %{owned?: true}} -> result(Error.protect(fn -> GateIO.set_output(id, value) end))
        {:ok, _} -> {:error, Error.new("io_not_manual", "Take manual control first.")}
        error -> result(error)
      end

    {:reply, reply, state}
  end

  def handle_call({:release, id}, _, state),
    do: {:reply, result(Error.protect(fn -> GateIO.release_output(id) end)), state}

  defp result(:ok), do: :ok
  defp result({:error, %{code: _, message: _}} = error), do: error
  defp result({:error, reason}), do: {:error, error(reason)}

  defp error(:unknown_output), do: Error.new("io_unknown_output", "This output is not defined.")

  defp error(:endpoint_unavailable),
    do:
      Error.new(
        "io_output_unavailable",
        "The output's plugin is not running. Start it before taking manual control."
      )

  defp error(:output_owned),
    do:
      Error.new(
        "io_output_owned",
        "Another writer, such as an automation, controls this output. It must release it first."
      )

  defp error(:invalid_output_write),
    do:
      Error.new(
        "io_invalid_value",
        "The value does not match the output's type or limits. Nothing was stored."
      )

  defp error(:io_catalog_unavailable),
    do:
      Error.new(
        "io_catalog_unavailable",
        "Saved I/O definitions are unsupported or unreadable. I/O is disabled; the file was left unchanged."
      )

  defp error(:not_output_owner),
    do: Error.new("io_not_manual", "Manual control does not hold this output.")

  defp error(_), do: Error.safe(nil)
end
