defmodule NervesGate.ErrorTest do
  use ExUnit.Case, async: true
  alias NervesGate.Error

  defmodule CallOwner do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, nil}
    def handle_call(:accepted, _, state), do: {:noreply, state}
  end

  test "a missing owner is unavailable; a lost reply is an unknown outcome" do
    assert {:error, %{code: "unavailable"}} =
             Error.protect(fn -> GenServer.call(NervesGateMissingCallOwner, :command) end)

    owner = start_supervised!(CallOwner)

    assert {:error, %{code: "outcome_unknown"}} =
             Error.protect(fn -> GenServer.call(owner, :accepted, 1) end)

    assert Process.alive?(owner)
  end

  test "read-only failures use the unavailable view without retrying" do
    unavailable = fn -> %{available: false} end

    assert Error.read(fn -> %{available: true} end, fn -> flunk("unexpected fallback") end) ==
             %{available: true}

    assert Error.read(
             fn -> GenServer.call(NervesGateMissingCallOwner, :status) end,
             unavailable
           ) == %{available: false}

    owner = start_supervised!(CallOwner)

    assert Error.read(fn -> GenServer.call(owner, :accepted, 1) end, unavailable) ==
             %{available: false}

    assert Process.alive?(owner)

    assert_raise ArgumentError, fn ->
      Error.read(fn -> raise ArgumentError end, unavailable)
    end
  end

  test "the boundary does not hide programming errors, throws or unrelated exits" do
    assert_raise ArgumentError, fn -> Error.protect(fn -> raise ArgumentError end) end
    assert catch_throw(Error.protect(fn -> throw(:application_bug) end)) == :application_bug
    assert catch_exit(Error.protect(fn -> exit(:application_bug) end)) == :application_bug
  end

  test "safe errors discard additional fields and never stringify unknown terms" do
    assert Error.safe(%{code: "domain_error", message: "Safe message", secret: "private"}) ==
             %{code: "domain_error", message: "Safe message"}

    assert %{code: "execution_failed", message: message} = Error.safe({:private, "secret"})
    refute message =~ "secret"
  end
end
