defmodule NervesGate.Command do
  @moduledoc "Runs external commands with a mandatory timeout."

  @spec run(Path.t(), [String.t()], pos_integer()) ::
          {:ok, String.t()}
          | {:error, :timeout | {:exit, non_neg_integer(), String.t()} | :not_found}
  def run(executable, arguments, timeout)
      when is_binary(executable) and is_list(arguments) and timeout > 0 do
    case System.find_executable(executable) do
      nil ->
        {:error, :not_found}

      path ->
        case MuonTrap.cmd(path, arguments, stderr_to_stdout: true, timeout: timeout) do
          {output, 0} -> {:ok, String.trim(output)}
          {_output, :timeout} -> {:error, :timeout}
          {output, code} -> {:error, {:exit, code, String.slice(String.trim(output), 0, 512)}}
        end
    end
  end
end
