defmodule NervesGate.Remote.Actions.LoginURL do
  @moduledoc """
  Explicit private query under the existing trusted-network authorization policy.
  The URL is delivered only to the requesting caller by a post-commit effect;
  it is never an Action result, agent state, observation or signal payload.
  """
  use Jido.Action, name: "remote_login_url", schema: Zoi.object(%{})
  alias NervesGate.Remote.Effect

  @impl true
  def run(_, %{agent_state: state}) do
    {:ok, %{state | outcome: :pending}, [%Effect{operation: :login_url}]}
  end
end
