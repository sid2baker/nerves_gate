defmodule Simulator.Scenarios.ProcessChaos do
  @moduledoc false
  alias Simulator.RecoveryChecks

  @steps 6
  @default_seed 40_465

  def spec,
    do: %{name: "seeded gateway and dependency crashes recover one at a time (no tailnet)"}

  def run(%{device: vm}) do
    seed = seed()
    if report = Process.get(:qemu_report), do: report.("Process chaos seed #{seed}")
    plan = plan(seed)
    RecoveryChecks.event(vm, :chaos_plan, %{seed: seed, plan: plan})

    try do
      for {target, times} <- plan, do: RecoveryChecks.crash(vm, target, times)
      RecoveryChecks.assert_projection_follows(vm)
    rescue
      error in ExUnit.AssertionError ->
        message = "#{Exception.message(error)} (replay with PROCESS_CHAOS_SEED=#{seed})"
        reraise %{error | message: message}, __STACKTRACE__
    end
  end

  @doc false
  def plan(seed) do
    gateway = RecoveryChecks.targets()
    targets = List.to_tuple(gateway ++ RecoveryChecks.dependencies())

    # Six quiet seconds between steps age out OTP's inclusive five-second window.
    {plan, _state} =
      Enum.map_reduce(1..@steps, :rand.seed_s(:exsss, seed), fn _, state ->
        {index, state} = :rand.uniform_s(tuple_size(targets), state)
        {repeat, state} = :rand.uniform_s(3, state)
        target = elem(targets, index - 1)
        {{target, if(target in gateway and repeat == 1, do: 2, else: 1)}, state}
      end)

    plan
  end

  # Set in the mix dev / mix ci session, not the CLI client that attaches to it.
  defp seed do
    case System.get_env("PROCESS_CHAOS_SEED") do
      nil ->
        @default_seed

      "random" ->
        :rand.uniform(1_000_000_000)

      value ->
        case Integer.parse(value) do
          {seed, ""} when seed >= 0 -> seed
          _ -> raise ArgumentError, "PROCESS_CHAOS_SEED must be a nonnegative integer or random"
        end
    end
  end
end
