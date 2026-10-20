defmodule NervesGateSim.ConfigurationTest do
  use ExUnit.Case, async: false

  test "runtime secrets preserve Bandit and the endpoint host configuration" do
    config =
      Config.Reader.read!(Path.join(NervesGateSim.source_dir(), "config/config.exs"),
        env: Mix.env(),
        target: :host
      )

    previous = Map.new(config, fn {app, _} -> {app, Application.get_all_env(app)} end)

    on_exit(fn ->
      for {app, settings} <- previous do
        for {key, _} <- Application.get_all_env(app), do: Application.delete_env(app, key)
        Application.put_all_env([{app, settings}])
      end
    end)

    assert :ok = NervesGateSim.configure()

    for endpoint <- [NervesGateWeb.Endpoint, NervesGateWeb.Simulator.Endpoint] do
      settings = Application.fetch_env!(:nerves_gate, endpoint)
      assert settings[:adapter] == Bandit.PhoenixAdapter
      assert settings[:pubsub_server] == NervesGate.PubSub
      assert settings[:http][:ip] == {127, 0, 0, 1}
      assert settings[:server] == false
      assert byte_size(settings[:secret_key_base]) >= 64
      assert is_binary(settings[:live_view][:signing_salt])
    end
  end
end
