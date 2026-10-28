defmodule NervesGate.WebFixture do
  @moduledoc "Start the gateway endpoint without a listener, restoring its config on exit."
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  alias NervesGateWeb.Endpoint

  def start_endpoint(signing_salt) do
    previous = Application.get_env(:nerves_gate, Endpoint)

    Application.put_env(:nerves_gate, Endpoint,
      server: false,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      live_view: [signing_salt: signing_salt]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate, Endpoint, previous),
        else: Application.delete_env(:nerves_gate, Endpoint)
    end)

    start_supervised!(Endpoint)
  end
end
