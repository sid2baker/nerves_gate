defmodule Workbench.CLI do
  @moduledoc "Shared session transport and bounded observation for Mix front ends; no admission policy."
  alias Workbench.Session

  def call(module, function, args \\ []), do: result!(Session.call(module, function, args))
  def command(module, function, args), do: result!(Session.command(module, function, args))

  def result!({:error, :not_running}),
    do: Mix.raise("No session. Start mix dev explicitly; use mix dev.doctor for diagnostics.")

  def result!({:error, message}) when is_binary(message), do: Mix.raise(message)
  def result!({:error, reason}), do: Mix.raise(inspect(reason))
  def result!(result), do: result

  def await_job(id, timeout \\ 900_000) do
    IO.puts("Job #{id}; inspect with mix dev.job #{id}")
    await(Workbench.Jobs, id, deadline(timeout), nil)
  end

  def await_runner(id, timeout \\ 900_000) do
    IO.puts("Runner #{id}; inspect with mix dev.job #{id}")
    await(Scenarios.Runner, id, deadline(timeout), nil)
  end

  defp await(owner, id, deadline, previous) do
    {:ok, operation} = call(owner, :fetch, [id])
    progress = Map.get(operation, :output) || Map.get(operation, :phase)
    if progress && progress != previous, do: IO.puts(progress)

    cond do
      operation.status != :running ->
        operation

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise(
          "Wait deadline reached, not cancellation. Inspect mix dev.job #{id}; do not resubmit."
        )

      true ->
        Process.sleep(500)
        await(owner, id, deadline, progress)
    end
  end

  def success!(%{status: status} = operation) when status in [:succeeded, :passed] do
    if result = Map.get(operation, :result), do: IO.puts(result)
    :ok
  end

  def success!(operation),
    do:
      Mix.raise(
        "#{operation.status}: #{Map.get(operation, :result) || Map.get(operation, :phase)}. Inspect mix dev.job #{operation.id}; do not replay uncertain operations."
      )

  def print_rows(nil, printed), do: printed

  def print_rows(run, printed) do
    Enum.reduce(run.rows, printed, fn row, printed ->
      if row.status in [:passed, :failed, :skipped] and not MapSet.member?(printed, row.id) do
        IO.puts("#{row.status}: #{row.id} (#{row.milliseconds} ms) #{row.detail}")
        MapSet.put(printed, row.id)
      else
        printed
      end
    end)
  end

  def print(value), do: IO.puts(inspect(value, pretty: true, limit: 100, printable_limit: 8_000))
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end
