defmodule NervesGateSim.Prerequisites do
  @moduledoc false
  @tools ~w(qemu-system-x86_64 fwup flock mkfs.ext4)

  def check!(additional \\ []) do
    unless :os.type() == {:unix, :linux} and
             String.starts_with?(to_string(:erlang.system_info(:system_architecture)), [
               "x86_64",
               "aarch64"
             ]) do
      Mix.raise(
        "The simulator requires Linux x86_64 or aarch64 with QEMU. There is no in-memory fallback."
      )
    end

    missing = Enum.reject(Enum.uniq(@tools ++ additional), &System.find_executable/1)

    if missing != [],
      do: Mix.raise("Missing simulator tools: #{Enum.join(missing, ", ")}. See sim/README.md.")

    version = output!("qemu-system-x86_64", ["--version"])

    case Regex.run(~r/version (\d+\.\d+\.\d+)/, version) do
      [_, number] ->
        unless Version.match?(number, ">= 8.2.0"), do: Mix.raise("QEMU 8.2 or newer is required.")

      _ ->
        Mix.raise("Cannot determine the installed QEMU version.")
    end

    backends = output!("qemu-system-x86_64", ["-netdev", "help"]) |> String.split()

    for backend <- ["user", "stream"] do
      unless backend in backends, do: Mix.raise("QEMU needs the #{backend} network backend.")
    end

    :ok
  end

  defp output!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> output
      _ -> Mix.raise("Cannot inspect QEMU prerequisites.")
    end
  end
end
