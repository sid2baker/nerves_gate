defmodule NervesGate.Error do
  @moduledoc "Safe administrative error shape and the shared process-call failure boundary."
  @type t :: %{code: String.t(), message: String.t()}

  def new(code, message), do: %{code: code, message: message}

  @doc false
  def safe(%{code: code, message: message}) when is_binary(code) and is_binary(message),
    do: new(code, message)

  def safe(_), do: new("execution_failed", "The operation failed. Check device diagnostics.")

  @doc "Read-only queries fall back to their domain's unavailable view on a failed call."
  def read(fun, unavailable) do
    case protect(fun) do
      {:error, _} -> unavailable.()
      result -> result
    end
  end

  @doc "Contain GenServer call exits without catching application exceptions or retrying work."
  def protect(fun) do
    fun.()
  catch
    :exit, {reason, {GenServer, :call, _}} ->
      error =
        if reason == :noproc,
          do:
            new(
              "unavailable",
              "Device control is unavailable. Reconnect and read the current state."
            ),
          else:
            new(
              "outcome_unknown",
              "The command reply was lost. Read the current state before retrying."
            )

      {:error, error}
  end
end
