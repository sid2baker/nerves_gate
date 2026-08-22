defmodule NervesGate.Tailscale do
  @moduledoc "Only application boundary for tailscale_ex calls."

  alias NervesGate.Identity
  alias NervesGate.Tailnet.Manager

  @server NervesGate.Tailscale.Daemon

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started, do: manager().ensure_started()

  @spec status() :: {:ok, map()} | {:error, atom()}
  def status do
    client = backend()
    safe(fn -> client.status(@server) end, :status_unavailable)
  end

  @spec enroll(String.t()) :: :ok | {:error, atom()}
  def enroll(auth_key) when is_binary(auth_key) and byte_size(auth_key) in 8..512 do
    client = backend()

    with :ok <- ensure_started(),
         result <- safe(fn -> client.login(@server, auth_key) end, :authentication_failed),
         :ok <- successful(result),
         result <-
           safe(
             fn -> client.cli(@server, "set", ["--hostname=#{Identity.get().hostname}"]) end,
             :hostname_failed
           ),
         :ok <- successful(result) do
      :ok
    else
      _failure -> {:error, :authentication_failed}
    end
  end

  def enroll(_auth_key), do: {:error, :authentication_failed}

  defp backend, do: Application.get_env(:nerves_gate, :tailscale_backend, Elixir.Tailscale)
  defp manager, do: Application.get_env(:nerves_gate, :tailscale_manager, Manager)

  defp successful(:ok), do: :ok
  defp successful({:ok, _output}), do: :ok
  defp successful(_failure), do: {:error, :operation_failed}

  defp safe(function, fallback) do
    function.()
  catch
    :exit, _reason -> {:error, fallback}
    _kind, _reason -> {:error, fallback}
  end
end
