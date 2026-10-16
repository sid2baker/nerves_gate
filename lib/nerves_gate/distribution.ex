defmodule NervesGate.Distribution do
  @moduledoc """
  Starts native OTP distribution when the existing Tailscale observations provide an address.
  An explicit development node bypasses Tailscale naming.
  No separate connection process, discovery or cookie store.
  """
  require Logger

  @cookie Application.compile_env(:nerves_gate, :distribution_cookie)

  def ensure_started(remote) do
    # Only the Nerves backend chooses its node; the development command names the UI.
    if NervesGate.target() in [:ec100, :x86_64] do
      case Application.get_env(:nerves_gate, :development_node) || node_name(remote) do
        nil -> :ok
        name when name == node() -> :ok
        name -> start(name)
      end
    end

    configure_cookie()
  end

  @doc false
  def configure_cookie do
    if @cookie && Node.alive?(), do: Node.set_cookie(@cookie)
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
