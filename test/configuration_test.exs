defmodule Dev.ConfigurationTest do
  use ExUnit.Case, async: false

  test "device discovery advertises only public metadata and never starts on the host" do
    for target <- [:ec100, :x86_64] do
      config =
        Config.Reader.read!(Path.join(Dev.root(), "firmware/config/firmware.exs"),
          env: :dev,
          target: target
        )

      assert config[:mdns_lite][:hosts] == [:hostname]
      assert [service] = config[:mdns_lite][:services]
      assert service.protocol == "nerves-device"
      assert service.port == 4000

      assert Enum.sort(service.txt_payload) ==
               Enum.sort([
                 "product=Nerves Gate",
                 "platform=#{target}",
                 "version=#{Dev.version()}"
               ])
    end

    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :mdns_lite))
  end

  test "runtime secrets preserve Bandit and the endpoint host configuration" do
    config =
      Config.Reader.read!(Path.join(Dev.root(), "config/config.exs"),
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

    # Native subsystem checks share this VM. Like firmware's host checks, they
    # may leave endpoint settings behind; configuration merging need not erase them.
    Application.put_env(:nerves_gate, NervesGateWeb.Endpoint, server: false)

    assert :ok = Dev.configure()

    settings = Application.fetch_env!(:nerves_gate_dev, DevWeb.Endpoint)
    assert settings[:adapter] == Bandit.PhoenixAdapter
    assert settings[:pubsub_server] == NervesGate.PubSub
    assert settings[:http][:ip] == {127, 0, 0, 1}
    assert settings[:server] == false
    assert byte_size(settings[:secret_key_base]) >= 64
    assert is_binary(settings[:live_view][:signing_salt])
    assert Application.fetch_env!(:nerves_gate, :services) == []
    refute Keyword.has_key?(config[:nerves_gate], NervesGateWeb.Endpoint)
    refute Process.whereis(NervesGateWeb.Endpoint)
  end
end
