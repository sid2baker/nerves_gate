defmodule NervesGateWeb.SettingsLive do
  @moduledoc "Dedicated UI for guarded post-commissioning settings changes."

  use NervesGateWeb, :live_view

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Settings
  alias NervesGate.Setup
  alias NervesGate.Tailnet.Observer
  alias NervesGateWeb.FormHelpers
  alias NervesGateWeb.SettingsComponents

  @topics ~w(settings internet_configuration internet tailnet cluster)

  @impl true
  def mount(_params, _session, socket) do
    if Setup.status().ready do
      connection_id = connection_id()

      if connected?(socket),
        do: Enum.each(@topics, &Phoenix.PubSub.subscribe(NervesGate.PubSub, &1))

      socket =
        socket
        |> assign(connection_id: connection_id)
        |> refresh()
        |> schedule_tick()

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/commissioning")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="surface-grid min-h-screen">
      <div class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-6 sm:py-10">
        <header class="flex flex-col gap-4 border-b border-white/10 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-black uppercase tracking-[0.22em] text-emerald-400">NervesGate</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-white">Guarded settings</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-400">
              Candidates remain temporary until they pass local validation and are confirmed from
              a fresh management connection. Unconfirmed changes roll back automatically.
            </p>
          </div>
          <.link_button href={~p"/"} class="shrink-0">Back to status</.link_button>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <div class="mt-6 grid gap-6">
          <SettingsComponents.change_guard view={@view} settings={@settings} />
          <SettingsComponents.forms view={@view} disabled={not is_nil(@settings.pending)} />
        </div>
      </div>
    </main>
    """
  end

  @impl true
  def handle_event("stage-internet", %{"internet" => params}, socket) do
    stage_result(
      Settings.stage_internet(params, socket.assigns.connection_id),
      socket,
      "Internet candidate is being validated."
    )
  end

  def handle_event("stage-tailnet", %{"auth_token" => token}, socket) do
    stage_result(
      Settings.stage_tailnet(token, socket.assigns.connection_id),
      socket,
      "Tailnet candidate is being applied. Reconnect through the candidate Tailnet to keep it."
    )
  end

  def handle_event("stage-cluster", params, socket) do
    group = params |> get_in(["cluster", "group"]) |> FormHelpers.blank_to_nil()

    stage_result(
      Settings.stage_cluster(group, socket.assigns.connection_id),
      socket,
      "Cluster candidate is being validated."
    )
  end

  def handle_event("confirm-settings", %{"id" => id}, socket) do
    case Settings.confirm(id, socket.assigns.connection_id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Settings committed as known-good.") |> refresh()}

      {:error, :fresh_connection_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Reload this page through the candidate connection before confirming."
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Confirmation failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  def handle_event("revert-settings", %{"id" => id}, socket) do
    case Settings.revert(id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Persisted settings restored.") |> refresh()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Rollback failed: #{FormHelpers.format_error(reason)}")}
    end
  end

  @impl true
  def handle_info(:settings_tick, socket) do
    {:noreply, socket |> refresh() |> schedule_tick()}
  end

  def handle_info(_event, socket), do: {:noreply, refresh(socket)}

  defp stage_result({:ok, _pending}, socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> refresh() |> schedule_tick()}
  end

  defp stage_result({:error, reason}, socket, _message) do
    {:noreply,
     put_flash(socket, :error, "Candidate rejected: #{FormHelpers.format_error(reason)}")}
  end

  defp refresh(socket) do
    view = %{
      network_configuration: InternetManager.status(),
      tailnet: Observer.status(),
      cluster: ClusterManager.status()
    }

    socket
    |> assign(:view, view)
    |> assign(:settings, Settings.status(socket.assigns.connection_id))
  end

  defp schedule_tick(socket) do
    if connected?(socket) and socket.assigns.settings.pending do
      Process.send_after(self(), :settings_tick, 1_000)
    end

    socket
  end

  defp connection_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
