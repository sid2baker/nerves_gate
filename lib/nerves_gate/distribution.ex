defmodule NervesGate.Distribution do
  @moduledoc """
  Starts native OTP distribution when the existing Tailscale observations provide an address.
  No separate process, discovery, cookie store or build-time identity.
  """
  require Logger

  def ensure_started(remote) do
    # Host simulation must never start EPMD or change the workstation's node.
    if NervesGate.target() != :host do
      case node_name(remote) do
        nil -> :ok
        name when name == node() -> :ok
        name -> start(name)
      end
    end

    :ok
  end

  @doc false
  def node_name(%{available: true, simulated: false, state: "online", ipv4: ip})
      when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _} = address} -> :"nerves_gate@#{:inet.ntoa(address)}"
      _ -> nil
    end
  end

  def node_name(_), do: nil

  defp start(name) do
    # Node.start/2 starts OTP's distribution supervisor, but not the EPMD executable.
    epmd =
      Path.join([
        to_string(:code.root_dir()),
        "erts-#{:erlang.system_info(:version)}",
        "bin/epmd"
      ])

    with {_, 0} <- System.cmd(epmd, ["-daemon"], stderr_to_stdout: true),
         :ok <- stop_previous_node(),
         {:ok, _} <- Node.start(name, name_domain: :longnames) do
      Logger.info("Erlang distribution started as #{name}")
    else
      error -> Logger.warning("Could not start Erlang distribution: #{inspect(error)}")
    end
  rescue
    error in [ErlangError] ->
      Logger.warning("Could not start Erlang distribution: #{Exception.message(error)}")
  end

  defp stop_previous_node do
    # A different address means re-enrollment/address change, not a transient outage.
    if Node.alive?(), do: Node.stop(), else: :ok
  end
end
