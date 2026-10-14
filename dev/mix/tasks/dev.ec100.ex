defmodule Mix.Tasks.Dev.Ec100 do
  @moduledoc false
  use Mix.Task
  @shortdoc "Run the workstation UI against EC100"

  @impl true
  def run([]) do
    backend = Application.fetch_env!(:nerves_gate, :ec100_node) |> to_string()
    [_, address] = String.split(backend, "@", parts: 2)
    {:ok, socket} = :gen_udp.open(0, [:inet])

    ip =
      try do
        :ok = :gen_udp.connect(socket, String.to_charlist(address), 9)
        {:ok, {ip, _}} = :inet.sockname(socket)
        ip
      after
        :gen_udp.close(socket)
      end

    System.put_env("NERVES_GATE_BACKEND_NODE", backend)
    Mix.Task.rerun("loadconfig")
    Mix.Task.rerun("compile", ["--force"])
    {_, 0} = System.cmd("epmd", ["-daemon"])
    {:ok, _} = Node.start(:"nerves_gate_ui@#{:inet.ntoa(ip)}", name_domain: :longnames)
    Mix.Task.run("phx.server")
  end
end
