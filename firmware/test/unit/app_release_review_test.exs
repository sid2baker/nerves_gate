defmodule NervesGate.AppReleaseReviewTest do
  use ExUnit.Case, async: false
  alias NervesGate.Apps

  defp state(review) do
    %{
      blocked: nil,
      blocked_app: nil,
      job: nil,
      restored?: true,
      available?: true,
      release_review: review,
      entries: %{},
      running: %{},
      errors: %{}
    }
  end

  test "expired, missing and caller-supplied release data cannot authorize installation" do
    token = make_ref()
    expired = %{token: token, expires: System.monotonic_time(:millisecond) - 1, review: %{}}

    assert {:reply, {:error, :release_review_expired}, %{release_review: nil}} =
             Apps.handle_call({:install_release, token}, {self(), make_ref()}, state(expired))

    for value <- [token, %{"app" => "tailnet_subrouter", "version" => "1.1.0"}, "token"] do
      assert {:reply, {:error, :release_review_expired}, _} =
               Apps.handle_call({:install_release, value}, {self(), make_ref()}, state(nil))
    end
  end

  test "a timed-out or stale worker cannot pass the pre-extraction storage fence" do
    op = make_ref()
    blocked = %{blocked: :operation_timeout, job: %{op: op, task: %{pid: self()}}}

    assert {:reply, {:error, :applications_blocked}, ^blocked} =
             Apps.handle_call({:worker, op, :check_storage}, {self(), make_ref()}, blocked)

    assert {:reply, {:error, :applications_blocked}, ^blocked} =
             Apps.handle_call(
               {:worker, op, {:release_review, %{}}},
               {self(), make_ref()},
               blocked
             )

    assert {:reply, {:error, :stale_operation}, ^blocked} =
             Apps.handle_call(
               {:worker, make_ref(), :check_storage},
               {self(), make_ref()},
               blocked
             )
  end

  test "a confirmation consumes its reference before any download or lifecycle work" do
    assert Process.whereis(NervesGate.Storage) == nil

    unless Process.whereis(NervesGate.AppTasks),
      do: start_supervised!({Task.Supervisor, name: NervesGate.AppTasks})

    token = make_ref()
    review = %{token: token, expires: System.monotonic_time(:millisecond) + 10_000, review: %{}}

    assert {:noreply, admitted} =
             Apps.handle_call({:install_release, token}, {self(), make_ref()}, state(review))

    assert admitted.release_review == nil
    Process.cancel_timer(admitted.job.timer)
    assert {{:error, :storage_unavailable}, _} = Task.await(admitted.job.task)

    assert {:reply, {:error, :release_review_expired}, _} =
             Apps.handle_call({:install_release, token}, {self(), make_ref()}, %{
               admitted
               | job: nil
             })
  end
end
