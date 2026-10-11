defmodule NervesGate.Remote do
  @moduledoc "Tailscale command boundary. Slow daemon calls never block network recovery or UI reads."
  use GenServer
  alias NervesGate.Device.Error

  @callback snapshot(term()) :: map()
  @callback execute(atom(), map(), term()) :: :ok | {:ok, String.t()} | {:error, term()}
  @callback login_url(term()) :: String.t() | nil

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def command(action, params, server \\ __MODULE__),
    do: GenServer.call(server, {:command, action, params})

  def login_url(server \\ __MODULE__), do: GenServer.call(server, :login_url)
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, "remote")

  def unavailable do
    %{
      available: false,
      simulated: false,
      state: "unavailable",
      auth_state: "unknown",
      hostname: nil,
      dns_name: nil,
      ipv4: nil,
      version: nil,
      advertised_routes: nil,
      health: [],
      operation: nil,
      error: nil,
      verified: false,
      permitted_routes: nil
    }
  end

  def validate(action, params) when action in [:connect, :configure] do
    case params do
      %{"hostname" => name} when map_size(params) == 1 and is_binary(name) ->
        if Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, name),
          do: {:ok, %{hostname: String.downcase(name)}},
          else:
            {:error,
             Error.new(
               "invalid_parameters",
               "Use 1–63 letters, numbers or hyphens for the device name. Start and end with a letter or number."
             )}

      _ ->
        {:error, Error.new("invalid_parameters", "Supply only the device name.")}
    end
  end

  def validate(action, params) when action in [:disconnect, :login_url] and params == %{},
    do: {:ok, %{}}

  def validate(_, _), do: {:error, Error.new("invalid_parameters", "Invalid Tailscale command.")}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      adapter: Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :remote_adapter)),
      task: nil,
      timer: nil,
      operation: nil,
      error: nil,
      snapshot: nil,
      poll_ms: Keyword.get(opts, :poll_ms, 1_000),
      timeout: Keyword.get(opts, :timeout, 40_000)
    }

    send(self(), :poll)
    {:ok, refresh(state)}
  end

  @impl true
  def handle_call(:status, _, state) do
    state = refresh(state)
    {:reply, state.snapshot, state}
  end

  def handle_call(:login_url, _, %{adapter: {module, context}} = state) do
    # Enrollment URLs are secrets: explicit reads only, never in projections or broadcasts.
    url =
      try do
        module.login_url(context)
      catch
        _, _ -> nil
      end

    {:reply, safe_login_url(url), state}
  end

  def handle_call({:command, _, _}, _, %{task: task} = state) when not is_nil(task),
    do:
      {:reply, {:error, Error.new("remote_busy", "A Tailscale change is still running.")}, state}

  def handle_call({:command, action, params}, _, state) do
    state = refresh(state)

    with {:ok, validated} <- validate(action, params),
         true <- state.snapshot.available do
      {module, context} = state.adapter

      task =
        Task.async(fn ->
          try do
            module.execute(action, validated, context)
          catch
            _, _ -> {:error, :failed}
          end
        end)

      timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)

      state =
        refresh(%{
          state
          | task: task,
            timer: timer,
            operation: Atom.to_string(action),
            error: nil
        })

      {:reply, :ok, state}
    else
      false ->
        {:reply,
         {:error,
          Error.new(
            "remote_unavailable",
            "Tailscale is starting or unavailable. Try again shortly."
          )}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.timer)

    error =
      case result do
        :ok ->
          nil

        {:ok, _url} ->
          nil

        {:error, :needs_approval} ->
          nil

        {:error, :timeout} ->
          Error.new(
            "remote_timeout",
            "Tailscale is taking longer than expected. Check the connection and try again; login may still complete."
          )

        _ ->
          Error.new(
            "remote_failed",
            "Tailscale could not complete the change. Check the connection and try again. Some settings may have changed."
          )
      end

    {:noreply, refresh(%{state | task: nil, timer: nil, operation: nil, error: error})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state) do
    Process.cancel_timer(state.timer)

    {:noreply,
     refresh(%{
       state
       | task: nil,
         timer: nil,
         operation: nil,
         error:
           Error.new(
             "remote_failed",
             "Tailscale stopped responding. Check its status before retrying."
           )
     })}
  end

  def handle_info({:timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)

    {:noreply,
     refresh(%{
       state
       | task: nil,
         timer: nil,
         operation: nil,
         error:
           Error.new(
             "remote_timeout",
             "Tailscale stopped responding. The change may still complete; check its status before retrying."
           )
     })}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, refresh(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp refresh(%{adapter: {module, context}} = state) do
    observed =
      try do
        module.snapshot(context)
      catch
        _, _ -> unavailable()
      end

    snapshot =
      unavailable()
      |> Map.merge(observed)
      |> Map.merge(%{operation: state.operation, error: state.error})

    snapshot =
      Map.update!(snapshot, :health, fn warnings ->
        Enum.map(warnings, &String.replace(&1, ~r/https?:\/\/[^\s<>"']+/i, "[private URL]"))
      end)

    if snapshot != state.snapshot do
      Phoenix.PubSub.broadcast(NervesGate.PubSub, "remote", :remote_changed)
    end

    %{state | snapshot: snapshot}
  end

  defp safe_login_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil}
      when host in ["login.tailscale.com", "controlplane.tailscale.com"] ->
        url

      _ ->
        nil
    end
  end

  defp safe_login_url(_), do: nil
end
