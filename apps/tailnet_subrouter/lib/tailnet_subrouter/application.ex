defmodule TailnetSubrouter.Application do
  use Application

  def start(_, _) do
    if Code.ensure_loaded?(NervesGateSDK.Network) and
         function_exported?(NervesGateSDK.Network, :claim_local, 3) do
      Supervisor.start_link([TailnetSubrouter],
        strategy: :one_for_one,
        name: TailnetSubrouter.Supervisor
      )
    else
      {:error, :local_network_api_unavailable}
    end
  end
end
