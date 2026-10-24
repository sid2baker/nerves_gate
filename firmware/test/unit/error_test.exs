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
