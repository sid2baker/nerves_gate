defmodule NervesGate.Tailscale.Observer do
  @moduledoc "Temporary backend facade for the current NervesGateWeb layer."

  # Compatibility: remove this compatibility module during the NervesGateWeb refactor.
  defdelegate status(), to: NervesGate.Tailnet.Observer
  defdelegate poll_now(), to: NervesGate.Tailnet.Observer
  defdelegate actor_for_ip(ip), to: NervesGate.Tailnet.Observer
end
