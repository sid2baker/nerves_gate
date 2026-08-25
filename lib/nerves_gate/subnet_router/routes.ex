defmodule NervesGate.SubnetRouter.Routes do
  @moduledoc "Idempotent Tailscale route-advertisement boundary."

  alias NervesGate.Tailnet

  @spec apply(boolean(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def apply(enabled, routes) do
    advertised = if enabled, do: routes, else: []

    with :ok <-
           Tailscale.await_online(timeout: 30_000, require: [:authenticated, :tailscale_ipv4]),
         :ok <- Tailscale.set(ssh: false, advertise_routes: advertised),
         {:ok, applied} <- Tailscale.advertised_routes(),
         true <- applied == advertised or enabled do
      Tailnet.refresh()
      {:ok, if(enabled, do: applied, else: routes)}
    else
      false -> {:error, :route_withdrawal_failed}
      {:error, _reason} = error -> error
      _failure -> {:error, :route_update_failed}
    end
  end
end
