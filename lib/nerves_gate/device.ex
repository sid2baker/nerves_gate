defmodule NervesGate.Device do
  @moduledoc """
  Stateless public interface for LiveView, IEx/SSH and other client adapters.

  `projection/1` is a compatibility name for an on-demand, pure selection of
  authoritative domain observations. There is no Device process or stored read
  model. The two domains are read independently, not as an atomic snapshot.

  `dispatch/3` translates the eight public string commands to domain APIs backed
  by Jido Actions. `:expected_revision` checks only the commanded domain, inside
  admission and again at its serialized effect boundary. Observations are not
  configuration writes; network link changes do not invalidate a form revision.
  Always supply a trial ID when confirming or cancelling.

  `subscribe/1` binds PropertyTable subscriptions to the calling process. Read
  after subscribing and treat notifications as hints to re-read, not snapshots.
  Re-subscribe after reconnecting. Delivery is ephemeral, not a command log.
  An unknown outcome requires reading state before retrying a write.
  """
  alias NervesGate.Device.{Error, Selectors}
  alias NervesGate.{Network, Remote}

  defstruct network: Network, remote: Remote

  @doc "Inject domain supervisors for tests or independent gateway instances; starts no process."
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  def projection(device \\ new()) do
    Selectors.build(network_status(device.network), remote_status(device.remote))
  end

  def subscribe(device \\ new()) do
    observe(Network, device.network)
    observe(Remote, device.remote)
    :ok
  end

  @doc "Returns `{:ok, %{result: map, projection: map}}` or `{:error, %{error: map, projection: map}}`."
  def dispatch(action, params \\ %{}, opts \\ []) do
    device = Keyword.get(opts, :server, new())

    result =
      cond do
        not is_binary(action) ->
          {:error, Error.new("unknown_action", "Action IDs must be strings.")}

        not json_value?(params) ->
          invalid_parameters()

        true ->
          execute(action, params, device, opts)
      end

    view = projection(device)

    case result do
      {:ok, value} -> {:ok, %{result: value, projection: view}}
      {:error, error} -> {:error, %{error: Error.from(error), projection: view}}
    end
  end

  defp execute("network.validate", %{"network" => network} = params, _, _)
       when map_size(params) == 1 do
    case Network.validate(network) do
      {:ok, validated} -> {:ok, %{network: validated}}
      error -> error
    end
  end

  defp execute("network.propose", %{"network" => network} = params, device, opts)
       when map_size(params) == 1 do
    Network.propose(network, device.network, opts[:access], expected(opts, 0)) |> network_result()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp execute(action, %{"trial_id" => id} = params, device, opts)
       when action in ["network.confirm", "network.cancel"] and is_binary(id) and
              map_size(params) == 1 do
    result =
      if action == "network.confirm",
        do: Network.confirm(id, device.network, expected(opts, 0)),
        else: Network.cancel(id, device.network, expected(opts, 0))

    network_result(result)
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp execute("remote.login_url", params, device, _) when params == %{} do
    case Remote.login_url(device.remote) do
      {:error, _} = error -> error
      url -> {:ok, %{url: url}}
    end
  catch
    :exit, _ -> {:error, Error.new("remote_unavailable", "Tailscale is unavailable.")}
  end

  defp execute("remote." <> operation, params, device, opts)
       when operation in ["connect", "configure", "disconnect"] do
    # This finite translation preserves the public wire API; Jido owns execution/routing.
    action =
      case operation do
        "connect" -> :connect
        "configure" -> :configure
        "disconnect" -> :disconnect
      end

    case Remote.command(action, params, device.remote, expected(opts, 1)) do
      :ok -> {:ok, %{accepted: true}}
      error -> error
    end
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp execute(action, _, _, _)
       when action in [
              "network.validate",
              "network.propose",
              "network.confirm",
              "network.cancel",
              "remote.login_url"
            ],
       do: invalid_parameters()

  defp execute(_, _, _, _), do: {:error, Error.new("unknown_action", "Unknown device action.")}

  defp network_result(:ok), do: {:ok, %{}}
  defp network_result({:ok, id}), do: {:ok, %{trial_id: id}}
  defp network_result(error), do: error

  defp expected(opts, domain) do
    case Keyword.get(opts, :expected_revision) do
      nil -> nil
      value when is_binary(value) -> Enum.at(String.split(value, "|", parts: 2), domain, :invalid)
      _ -> :invalid
    end
  end

  defp observe(module, server) do
    module.observe(server)
  catch
    :exit, _ -> :ok
  end

  defp remote_status(remote) do
    Remote.status(remote)
  catch
    :exit, _ -> Remote.unavailable()
  end

  defp network_status(network) do
    status = Network.status(network)
    %{status | error: status.error && Error.from(status.error)}
  catch
    :exit, _ -> nil
  end

  defp invalid_parameters,
    do:
      {:error,
       Error.new("invalid_parameters", "Supply exactly the action's required JSON parameters.")}

  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json_value?([]), do: true
  defp json_value?([head | tail]), do: json_value?(head) and is_list(tail) and json_value?(tail)

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and json_value?(item)
      end)

  defp json_value?(_), do: false
end
