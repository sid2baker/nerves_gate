defmodule NervesGate.Network.CellularCommissioningTest do
  use ExUnit.Case, async: true
  require Logger
  alias NervesGate.Network.Cellular

  test "commissioning accepts only numeric PINs and named operations" do
    for pin <- ["1234", "12345678"] do
      assert Cellular.parameters(:unlock, [pin]) == :ok
      assert Cellular.parameters(:save_pin, [pin]) == :ok
      assert Cellular.parameters(:change_pin, [pin, "4321"]) == :ok
      assert Cellular.parameters(:set_pin_lock, [true, pin]) == :ok
      assert Cellular.parameters(:set_pin_lock, [false, pin]) == :ok
    end

    for pin <- [nil, 1234, "123", "123456789", "１２３４", "1234\rAT+CFUN=0", <<255>>] do
      assert Cellular.parameters(:unlock, [pin]) == {:error, :cellular_parameters}
      assert Cellular.parameters(:save_pin, [pin]) == {:error, :cellular_parameters}
    end

    assert Cellular.parameters(:refresh, []) == :ok
    assert Cellular.parameters(:forget_pin, []) == :ok

    for {operation, params} <- [
          {:auto_unlock, []},
          {:initialize, []},
          {:command, ["AT+CPIN=1234"]},
          {:set_pin_lock, ["true", "1234"]},
          {:refresh, ["1234"]},
          {:unlock, []}
        ] do
      assert Cellular.parameters(operation, params) == {:error, :cellular_parameters}
    end
  end

  test "hot-plug setup changes only a known incorrect detection setting" do
    assert Cellular.hotplug_commands({:ok, [~s(+QSIMDET: 1,1,"SIM1")]}, 1) == {:ok, []}
    assert Cellular.hotplug_commands({:ok, ["+QSIMDET: 1,1"]}, 1) == {:ok, []}

    for setting <- [~s(+QSIMDET: 0,0,"SIM1"), ~s(+QSIMDET: 1,0,"SIM1")] do
      assert Cellular.hotplug_commands({:ok, [setting]}, 1) ==
               {:ok, ["AT+QSIMDET=1,1", "AT+CFUN=0", "AT+CFUN=1"]}
    end

    for response <- [
          {:error, :timeout},
          {:ok, []},
          {:ok, ["unexpected"]},
          {:ok, [~s(+QSIMDET: 0,0,"SIM2")]}
        ] do
      assert Cellular.hotplug_commands(response, 1) == {:error, :cellular_setup_failed}
    end

    assert Cellular.hotplug_commands({:ok, ["+QSIMDET: 0,0"]}, nil) ==
             {:error, :cellular_setup_failed}
  end

  test "SIM state, PIN protection and attempt counts stay unknown unless explicitly reported" do
    for {line, state} <- [
          {"+CPIN: READY", :ready},
          {"+CPIN: SIM PIN", :pin_required},
          {"+CPIN: SIM PUK", :puk_required},
          {"+CPIN: SIM PIN2", :pin2_required},
          {"+CPIN: SIM PUK2", :puk2_required}
        ] do
      assert Cellular.sim_state({:ok, [line]}) == state
    end

    assert Cellular.sim_state({:error, {:cme, "10"}}) == :absent
    assert Cellular.sim_state({:error, :not_running}) == :unknown
    assert Cellular.sim_state({:ok, ["OK"]}) == :unknown
    assert Cellular.pin_lock({:ok, ["+CLCK: 1"]}) == :enabled
    assert Cellular.pin_lock({:ok, ["+CLCK: 0"]}) == :disabled
    assert Cellular.pin_lock({:ok, ["OK"]}) == :unknown
    assert Cellular.attempts({:ok, [~s(+QPINC: "SC",0,10)]}) == 0
    assert Cellular.attempts({:ok, [~s(+QPINC: "SC",3,10)]}) == 3
    assert Cellular.attempts({:ok, [~s(+QPINC: "P2",3,10)]}) == nil
    assert Cellular.attempts({:error, :not_supported}) == nil
    assert Cellular.registration({:ok, ["+CEREG: 2,1"]}) == :registered_home
    assert Cellular.registration({:ok, ["+CEREG: 2,5"]}) == :registered_roaming
    assert Cellular.registration({:ok, ["OK"]}) == :unknown
  end

  test "SIM binding requires a fresh, strict QCCID result, never a cached identifier" do
    id = "89880000000000000001"
    assert Cellular.sim_identity({:ok, ["+QCCID: #{id}"]}) == id
    assert Cellular.sim_identity({:ok, ["+QCCID: #{id}F"]}) == id

    for result <- [
          {:ok, [id]},
          {:ok, ["+QCCID: 123"]},
          {:ok, ["+QCCID: #{id}EXTRA"]},
          {:error, {:cme, "SIM PIN required"}}
        ] do
      assert Cellular.sim_identity(result) == nil
    end
  end

  test "forget remains available without a modem but shares network admission" do
    status = status()
    assert Cellular.available(status) == :ok

    assert Cellular.available(%{status | observed: %{status.observed | cellular: nil}}) ==
             {:error, :cellular_missing}

    disabled = put_in(status.config["network"]["internet"], %{"mode" => "ethernet"})
    assert Cellular.available(disabled) == {:error, :cellular_disabled}
    assert Cellular.available(disabled, :forget_pin) == :ok
    assert Cellular.available(disabled, :forget_authentication) == :ok
    assert Cellular.available(disabled, :save_authentication) == {:error, :cellular_disabled}

    for op <- [:refresh, :unlock, :forget_pin, :save_authentication, :forget_authentication] do
      assert Cellular.available(%{status | phase: :cellular}, op) ==
               {:error, :operation_in_progress}

      assert Cellular.available(%{status | trial: %{network: status.config["network"]}}, op) ==
               {:error, :trial_in_progress}

      assert Cellular.available(%{status | recovering: true}, op) ==
               {:error, :recovery_in_progress}
    end

    assert Cellular.available(nil, :forget_pin) == {:error, :cellular_unsupported}
    assert Cellular.available(nil, :forget_authentication) == {:error, :cellular_unsupported}
  end

  test "disabling or removing a modem clears observations but not saved PIN metadata" do
    status = status()
    cellular = %{Cellular.empty() | sim: :ready, pin_saved: true, auto_unlock: :blocked}
    status = %{status | cellular: cellular}
    assert Cellular.view(status).sim == :ready
    disabled = put_in(status.config["network"]["internet"], %{"mode" => "ethernet"})
    assert Cellular.view(disabled).sim == :unknown
    assert Cellular.view(disabled).pin_saved
    assert Cellular.view(disabled).auto_unlock == :blocked
    missing = %{status | observed: %{status.observed | cellular: nil}}
    assert Cellular.view(missing).pin_saved
    assert Cellular.view(missing).sim == :unknown
  end

  test "primary log filter removes PINs and private identity from OTP report shapes" do
    event = %{
      level: :error,
      msg:
        {:report,
         %{
           last_message: {:cellular, :change_pin, ["4812", "2580"]},
           reason: {:command, ~s(AT+CPIN="4812"), 10_000},
           lock: ~c"AT+CLCK=\"SC\",1,\"4812\"",
           state: %{"iccid" => "private-id", pin: "4812", fingerprint: "private-hash"},
           opts: [current_pin: "4812", new_pin: "2580"],
           stack: {NervesGate.Network.CellularPIN, :save, ["4812", "private-id"]}
         }},
      meta: %{mfa: {__MODULE__, :example, 0}}
    }

    filtered = Cellular.filter_log(event, nil)
    text = inspect(filtered)
    for secret <- ["4812", "2580", "private-hash", "private-id"], do: refute(text =~ secret)
    assert filtered.level == :error
    assert filtered.meta == event.meta
    assert text =~ "redacted"
    normal = %{msg: {:report, %{uri: %URI{path: "/normal"}, file: ~c"source.ex"}}}
    assert Cellular.filter_log(normal, nil) == normal
  end

  test "installed primary filter redacts commands before logger handlers capture them" do
    output = ExUnit.CaptureLog.capture_log(fn -> Logger.error(~s(AT+CPWD="SC","4812","2580")) end)
    assert output =~ "REDACTED SIM COMMAND"
    refute output =~ "4812"
    refute output =~ "2580"
  end

  defp status do
    %{
      config: %{"network" => %{"internet" => %{"mode" => "cellular", "apn" => "example"}}},
      observed: %{cellular_supported: true, cellular: %{present: true}},
      cellular: Cellular.empty(),
      recovering: false,
      trial: nil,
      phase: :idle
    }
  end
end
