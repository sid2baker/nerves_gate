defmodule NervesGate.Recovery do
  @moduledoc "Local, idempotent recovery-mode activation API."

  @spec activate() :: :ok
  def activate do
    NervesGate.Setup.recover(:local_action)
  end
end
