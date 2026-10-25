defmodule NervesGate.CellularTest do
  use ExUnit.Case, async: false
  require Logger
  alias NervesGate.Cellular

  test "commissioning accepts only numeric PINs and named operations" do
    for pin <- ["1234", "12345678"] do
      assert Cellular.parameters(:unlock, [pin]) == :ok
      assert Cellular.parameters(:save_pin, [pin]) == :ok
      assert Cellular.parameters(:change_pin, [pin, "4321"]) == :ok
      assert Cellular.parameters(:set_pin_lock, [true, pin]) == :ok
      assert Cellular.parameters(:set_pin_lock, [false, pin]) == :ok
    end

    for pin <- [nil, 1234, "123", "123456789", "１２３４", "1234\rAT+CFUN=0", <<255>>] do
      assert Cellular.parameters(:unlock, [pin]) ==
               {:error,
                %{
                  code: "invalid_parameters",
                  message: "Use 4–8 digit SIM PINs and a boolean PIN-protection setting."
                }}

      assert Cellular.parameters(:save_pin, [pin]) ==
               {:error,
                %{
                  code: "invalid_parameters",
                  message: "Use 4–8 digit SIM PINs and a boolean PIN-protection setting."
                }}
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
      assert Cellular.parameters(operation, params) ==
               {:error,
                %{
                  code: "invalid_parameters",
                  message: "Use 4–8 digit SIM PINs and a boolean PIN-protection setting."
                }}
    end
  end

  test "PIN saving needs enabled protection and backend commands require fresh SIM state" do
    base = status()

    for operation <- [:unlock, :save_pin, :change_pin, :set_pin_lock, :reconnect] do
      assert {:error, _} = Cellular.available(base, operation)
    end

    ready = %{base | cellular: %{base.cellular | sim: :ready, pin_lock: :disabled}}
    assert {:error, %{code: "cellular_pin_not_required"}} = Cellular.available(ready, :save_pin)
    assert Cellular.available(ready, :reconnect) == :ok
    assert Cellular.parameters(:reconnect, []) == :ok
    assert {:error, _} = Cellular.parameters(:reconnect, ["1234"])
    assert {:error, _} = Cellular.pin_saving_available(:unknown)
    protected = put_in(ready.cellular.pin_lock, :enabled)
    assert Cellular.available(protected, :save_pin) == :ok
    locked = put_in(ready.cellular.sim, :pin_required)
    assert Cellular.available(locked, :unlock) == :ok
    assert {:error, _} = Cellular.available(locked, :reconnect)
  end

  test "PIN lock changes cannot verify or store a PIN by reapplying the same state" do
    alias NervesGate.Cellular.SIM

    assert {:ok, ~s(AT+CLCK="SC",1,"4812"), "4812"} =
             SIM.protection_command(:disabled, true, "4812")

    assert {:ok, ~s(AT+CLCK="SC",0,"4812"), "4812"} =
             SIM.protection_command(:enabled, false, "4812")

    for {lock, enabled} <- [
          {:enabled, true},
          {:disabled, false},
          {:unknown, true},
          {:unknown, false}
        ] do
      assert {:error, %{code: "cellular_pin_protection_unchanged"}} =
               SIM.protection_command(lock, enabled, "4812")
    end
  end

  test "command outcomes survive automatic refresh, including failures and cleared observations" do
    start_supervised!({PropertyTable, name: NervesGate.Settings})
    previous = %{Cellular.empty() | operation: :save_pin, sim: :ready, pin_attempts_remaining: 3}
    error = %{code: "cellular_incorrect_pin", message: "Rejected; no retry was sent."}
    tracked = Cellular.complete({:error, error}, previous, 701)
    assert tracked.result.id == 701
    failed = Cellular.complete({:error, error}, previous)
    assert failed.result == %{operation: :save_pin, error: error}
    assert failed.sim == :unknown
    assert failed.pin_attempts_remaining == nil

    refreshing = %{failed | operation: :refresh, error: nil}
    observed = %{Cellular.empty() | sim: :ready, pin_lock: :enabled}
    refreshed = Cellular.complete({:ok, observed}, refreshing)
    assert refreshed.result == failed.result
    assert refreshed.sim == :ready
    assert refreshed.error == nil
    assert Cellular.reset(refreshed).result == failed.result

    saving = %{refreshed | operation: :save_authentication}
    saved = Cellular.complete({:ok, Cellular.cached()}, saving)
    assert saved.result == %{operation: :save_authentication, error: nil}
    assert saved.operation == nil
    assert saved.sim == :ready
    assert saved.pin_lock == :enabled
    assert saved.pin_saved == refreshed.pin_saved
    assert Cellular.available(%{status() | cellular: saved}, :reconnect) == :ok

    failed_storage = Cellular.complete({:error, error}, saving)
    assert failed_storage.sim == :ready
    assert failed_storage.result.error == error

    forgetting = %{saved | operation: :forget_pin}
    forgotten = Cellular.complete({:ok, Cellular.cached()}, forgetting)
    assert forgotten.sim == :ready
    assert forgotten.authentication == saved.authentication

    initialization = Cellular.complete({:error, error}, %{observed | operation: :initialize})
    assert initialization.result == %{operation: :initialize, error: error}

    assert Cellular.complete({:ok, observed}, %{initialization | operation: :refresh}).result ==
             initialization.result
  end

  test "hot-plug setup changes only a known incorrect detection setting" do
    assert NervesGate.Cellular.Modem.hotplug_commands({:ok, [~s"+QSIMDET: 1,1,\"SIM1\""]}, 1) ==
             {:ok, []}

    assert NervesGate.Cellular.Modem.hotplug_commands({:ok, ["+QSIMDET: 1,1"]}, 1) == {:ok, []}

    for setting <- [~s(+QSIMDET: 0,0,"SIM1"), ~s(+QSIMDET: 1,0,"SIM1")] do
      assert NervesGate.Cellular.Modem.hotplug_commands({:ok, [setting]}, 1) ==
               {:ok, ["AT+QSIMDET=1,1", "AT+CFUN=0", "AT+CFUN=1"]}
    end

    for response <- [
          {:error, :timeout},
          {:ok, []},
          {:ok, ["unexpected"]},
          {:ok, [~s(+QSIMDET: 0,0,"SIM2")]}
        ] do
      assert NervesGate.Cellular.Modem.hotplug_commands(response, 1) ==
               {:error,
                %{
                  code: "cellular_setup_failed",
                  message:
                    "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
                }}
    end

    assert NervesGate.Cellular.Modem.hotplug_commands({:ok, ["+QSIMDET: 0,0"]}, nil) ==
             {:error,
              %{
                code: "cellular_setup_failed",
                message:
                  "SIM hot-plug setup did not complete. Check the modem before restarting cellular; no PIN was sent."
              }}
  end

  test "SIM state, PIN protection and attempt counts stay unknown unless explicitly reported" do
    for {line, state} <- [
          {"+CPIN: READY", :ready},
          {"+CPIN: SIM PIN", :pin_required},
          {"+CPIN: SIM PUK", :puk_required},
          {"+CPIN: SIM PIN2", :pin2_required},
          {"+CPIN: SIM PUK2", :puk2_required}
        ] do
      assert NervesGate.Cellular.SIM.sim_state({:ok, [line]}) == state
    end

    assert NervesGate.Cellular.SIM.sim_state({:error, {:cme, "10"}}) == :absent
    assert NervesGate.Cellular.SIM.sim_state({:error, :not_running}) == :unknown
    assert NervesGate.Cellular.SIM.sim_state({:ok, ["OK"]}) == :unknown
    assert NervesGate.Cellular.SIM.pin_lock({:ok, ["+CLCK: 1"]}) == :enabled
    assert NervesGate.Cellular.SIM.pin_lock({:ok, ["+CLCK: 0"]}) == :disabled
    assert NervesGate.Cellular.SIM.pin_lock({:ok, ["OK"]}) == :unknown
    assert NervesGate.Cellular.SIM.attempts({:ok, [~s"+QPINC: \"SC\",0,10"]}) == 0
    assert NervesGate.Cellular.SIM.attempts({:ok, [~s"+QPINC: \"SC\",3,10"]}) == 3
    assert NervesGate.Cellular.SIM.attempts({:ok, [~s"+QPINC: \"P2\",3,10"]}) == nil
    assert NervesGate.Cellular.SIM.attempts({:error, :not_supported}) == nil
    assert NervesGate.Cellular.SIM.registration({:ok, ["+CEREG: 2,1"]}) == :registered_home
    assert NervesGate.Cellular.SIM.registration({:ok, ["+CEREG: 2,5"]}) == :registered_roaming
    assert NervesGate.Cellular.SIM.registration({:ok, ["OK"]}) == :unknown
  end

  test "SIM binding requires a fresh, strict QCCID result, never a cached identifier" do
    id = "89880000000000000001"
    assert NervesGate.Cellular.SIM.sim_identity({:ok, ["+QCCID: #{id}"]}) == id
    assert NervesGate.Cellular.SIM.sim_identity({:ok, ["+QCCID: #{id}F"]}) == id

    for result <- [
          {:ok, [id]},
          {:ok, ["+QCCID: 123"]},
          {:ok, ["+QCCID: #{id}EXTRA"]},
          {:error, {:cme, "SIM PIN required"}}
        ] do
      assert NervesGate.Cellular.SIM.sim_identity(result) == nil
    end
  end

  test "forget remains available without a modem but shares network admission" do
    status = status()
    assert Cellular.available(status) == :ok

    assert Cellular.available(%{status | observed: %{status.observed | cellular: nil}}) ==
             {:error,
              %{
                code: "cellular_missing",
                message:
                  "The configured cellular interface is not detected. Check modem power and USB enumeration."
              }}

    disabled = put_in(status.config["network"]["internet"], %{"mode" => "ethernet"})

    assert Cellular.available(disabled) == :ok
    assert {:error, %{code: "cellular_disabled"}} = Cellular.available(disabled, :reconnect)
    locked = put_in(disabled.cellular.sim, :pin_required)
    assert Cellular.available(locked, :unlock) == :ok

    assert Cellular.available(disabled, :forget_pin) == :ok
    assert Cellular.available(disabled, :forget_authentication) == :ok

    assert Cellular.available(disabled, :save_authentication) == :ok

    for op <- [:refresh, :unlock, :forget_pin, :save_authentication, :forget_authentication] do
      assert Cellular.available(%{status | phase: :cellular}, op) ==
               {:error,
                %{
                  code: "operation_in_progress",
                  message: "Wait for the current operation to finish."
                }}

      assert Cellular.available(%{status | trial: %{network: status.config["network"]}}, op) ==
               {:error,
                %{
                  code: "trial_in_progress",
                  message: "Keep or restore the network trial before changing cellular setup."
                }}

      assert Cellular.available(%{status | recovering: true}, op) ==
               {:error,
                %{
                  code: "recovery_in_progress",
                  message: "Wait for saved settings to be restored before trying again."
                }}
    end

    for operation <- [:forget_pin, :forget_authentication] do
      assert Cellular.available(nil, operation) ==
               {:error,
                %{
                  code: "unavailable",
                  message: "Network control is unavailable. Reconnect and read the current state."
                }}
    end
  end

  test "SIM observations remain available without mobile data; removal clears them" do
    status = status()
    cellular = %{Cellular.empty() | sim: :ready, pin_saved: true, auto_unlock: :blocked}
    status = %{status | cellular: cellular}
    assert Cellular.view(status).sim == :ready
    disabled = put_in(status.config["network"]["internet"], %{"mode" => "ethernet"})
    assert Cellular.view(disabled).sim == :ready
    refute Cellular.view(disabled).enabled
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
           tracked: {:cellular, :unlock, ["4812"], :tracked},
           reason: {:command, ~s(AT+CPIN="4812"), 10_000},
           lock: ~c"AT+CLCK=\"SC\",1,\"4812\"",
           state: %{"iccid" => "private-id", pin: "4812", fingerprint: "private-hash"},
           opts: [current_pin: "4812", new_pin: "2580"],
           stack: {NervesGate.Cellular.SIM, :save, ["4812", "private-id"]}
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

  test "web logs filter both PINs and private PAP credentials before formatting" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "pin" => "4812",
        "username" => "private-user",
        "password" => "private-password"
      })

    for secret <- ["4812", "private-user", "private-password"],
        do: refute(inspect(filtered) =~ secret)
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
