defmodule Workbench.Distribution do
  @moduledoc """
  The session's hidden node: unique per workstation, checkout and session directory,
  and stable across restarts so attached tools can reconnect.
  """
  def start!(dir) do
    epmd =
      Path.join([
        to_string(:code.root_dir()),
        "erts-#{:erlang.system_info(:version)}",
        "bin/epmd"
      ])

    {_, 0} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
    Application.put_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})

    identity =
      :crypto.hash(:sha256, [File.read!("/etc/machine-id"), Path.expand(dir)])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    name = String.to_atom("workbench_#{identity}@127.0.0.1")
    {:ok, _} = Node.start(name, name_domain: :longnames, hidden: true)
    Node.set_cookie(:mycookie)
    name
  end
end
