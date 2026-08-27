defmodule NervesGate.ShoehornHandlerTest do
  use ExUnit.Case, async: true

  alias NervesGate.ShoehornHandler

  test "retries a configured essential application only once by default" do
    owner = self()

    restart = fn application ->
      send(owner, {:restart, application})
      {:ok, [application]}
    end

    assert {:ok, state} =
             ShoehornHandler.init(
               retry_applications: [:nerves_runtime],
               restart_application: restart
             )

    assert {:continue, state} =
             ShoehornHandler.application_exited(:nerves_runtime, :boot_failed, state)

    assert_receive {:restart, :nerves_runtime}

    assert {:continue, _state} =
             ShoehornHandler.application_exited(:nerves_runtime, :boot_failed_again, state)

    refute_receive {:restart, :nerves_runtime}
  end

  test "resumes the release after an essential application recovers" do
    owner = self()

    restart = fn application ->
      send(owner, {:restart, application})
      {:ok, [application]}
    end

    assert {:ok, state} =
             ShoehornHandler.init(
               retry_applications: [:nerves_runtime],
               retry_attempts: 1,
               resume_application: :nerves_gate,
               restart_application: restart
             )

    assert {:continue, _state} =
             ShoehornHandler.application_exited(:nerves_runtime, :boot_failed, state)

    assert_receive {:restart, :nerves_runtime}
    assert_receive {:restart, :nerves_gate}
  end

  test "does not restart unconfigured applications" do
    owner = self()

    restart = fn application ->
      send(owner, {:restart, application})
      {:ok, [application]}
    end

    assert {:ok, state} =
             ShoehornHandler.init(
               retry_applications: [:nerves_runtime],
               retry_attempts: 1,
               restart_application: restart
             )

    assert {:continue, ^state} =
             ShoehornHandler.application_exited(:nerves_gate, :boot_failed, state)

    refute_receive {:restart, :nerves_gate}
  end
end
