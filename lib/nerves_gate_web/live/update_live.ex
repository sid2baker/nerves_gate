defmodule NervesGateWeb.UpdateLive do
  @moduledoc "Tailnet-only firmware discovery, installation, trial validation, and rollback UI."

  use NervesGateWeb, :live_view

  import NervesGateWeb.GatewayComponents

  @impl true
  def mount(_params, web_session, socket) do
    {:ok, session, fleet} = NervesGate.connect()

    if NervesGate.configured?(session) do
      socket =
        socket
        |> assign(
          connection_id: connection_id(),
          tailnet_access: Map.get(web_session, "tailnet_access", false),
          fleet: fleet,
          firmware: firmware(fleet)
        )
        |> assign_private(session: session, session_monitor: Process.monitor(session))

      {:ok, socket}
    else
      NervesGate.disconnect(session)
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
            <p class="text-[11px] font-black uppercase tracking-[0.22em] text-emerald-400">
              Recoverable maintenance
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-white">Firmware update</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-400">
              Firmware remains temporary until this gateway is healthy and you explicitly accept it
              from a fresh Tailnet connection.
            </p>
          </div>
          <.link_button href={~p"/"} class="bg-zinc-800 text-zinc-100 hover:bg-zinc-700">
            Back to status
          </.link_button>
        </header>

        <div class="mt-5"><.flash_group flash={@flash} /></div>

        <section class="mt-6 grid gap-4 sm:grid-cols-3">
          <.summary label="Running version" value={current(@firmware, :version, "Unknown")} />
          <.summary label="Validation" value={validation_label(@firmware.validation)} />
          <.summary label="Update available" value={available_label(@firmware.available)} />
        </section>

        <.card class="mt-6">
          <.section_header
            eyebrow="Lifecycle"
            title={phase_title(@firmware.phase)}
            description={phase_description(@firmware)}
          >
            <:action>
              <.badge tone={phase_tone(@firmware.phase)}>{humanize(@firmware.phase)}</.badge>
            </:action>
          </.section_header>

          <div :if={@firmware.phase == :unsupported} class="mt-5 rounded-xl border border-amber-400/20 bg-amber-400/8 p-4 text-sm leading-6 text-amber-100">
            This Nerves system does not advertise a safe automatic-fallback contract. Firmware
            installation is disabled.
          </div>

          <div :if={@firmware.available} class="mt-5 grid gap-4 rounded-xl border border-white/8 bg-black/15 p-4 sm:grid-cols-2">
            <.detail_list items={release_details(@firmware.available)} />
            <div class="flex flex-wrap content-end items-end justify-start gap-3 sm:justify-end">
              <.button
                :if={@firmware.phase in [:idle, :failed]}
                phx-click="prepare"
                phx-value-id={@firmware.available.id}
                phx-disable-with="Starting download…"
              >
                Download and verify
              </.button>
              <.button
                :if={@firmware.phase == :ready}
                phx-click="install"
                phx-value-id={@firmware.available.id}
                phx-disable-with="Running checks…"
                data-confirm="Install this verified firmware and reboot into a temporary trial?"
              >
                Install trial firmware
              </.button>
            </div>
          </div>

          <div :if={@firmware.artifact} class="mt-5">
            <div class="mb-2 flex items-center justify-between text-xs text-zinc-400">
              <span>{artifact_label(@firmware)}</span>
              <span>{@firmware.progress || 0}%</span>
            </div>
            <progress
              class="h-2 w-full overflow-hidden rounded-full accent-emerald-400"
              value={@firmware.progress || 0}
              max="100"
            >
              {@firmware.progress || 0}%
            </progress>
          </div>

          <div :if={@firmware.phase in [:idle, :ready, :failed]} class="mt-5 flex flex-wrap gap-3">
            <.button tone={:secondary} phx-click="check" phx-disable-with="Checking releases…">
              Check for updates
            </.button>
          </div>
        </.card>

        <.card :if={@firmware.trial} class="mt-6 border-amber-400/25">
          <.section_header
            eyebrow="Unvalidated trial"
            title={"Firmware #{@firmware.trial.version} is temporary"}
            description={trial_description(@firmware.trial)}
          >
            <:action>
              <.badge tone={if @firmware.trial.confirmable, do: :good, else: :warning}>
                {if @firmware.trial.confirmable, do: "Healthy", else: "Checking"}
              </.badge>
            </:action>
          </.section_header>

          <div class="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
            <.detail_list items={health_details(@firmware.health)} />
            <div class="flex flex-wrap gap-3">
              <.button
                phx-click="accept"
                phx-value-id={@firmware.trial.id}
                disabled={not @firmware.trial.confirmable or not @tailnet_access}
                phx-disable-with="Accepting firmware…"
                data-confirm="Accept this firmware permanently?"
              >
                Accept firmware
              </.button>
              <.button
                tone={:danger}
                phx-click="rollback"
                phx-value-id={@firmware.trial.id}
                phx-disable-with="Scheduling rollback…"
                data-confirm="Reboot immediately into the previous known-good firmware?"
              >
                Roll back now
              </.button>
            </div>
          </div>

          <p :if={not @firmware.trial.confirmable} class="mt-4 text-sm leading-6 text-amber-200">
            Acceptance remains locked until all required checks stay healthy. Closing this page does
            not cancel the rollback deadline.
          </p>
        </.card>

        <.card class="mt-6">
          <.section_header
            eyebrow="Trust policy"
            title="Signed and system-specific"
            description="GitHub distributes release files; embedded public keys decide which firmware is trusted."
          />
          <div class="mt-5">
            <.detail_list items={current_details(@firmware.current)} />
          </div>
        </.card>
      </div>
    </main>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp summary(assigns) do
    ~H"""
    <div class="rounded-2xl border border-white/10 bg-zinc-900/70 p-4">
      <span class="block text-xs font-semibold uppercase tracking-wider text-zinc-500">{@label}</span>
      <strong class="mt-2 block text-lg text-zinc-100">{@value}</strong>
    </div>
    """
  end

  @impl true
  def handle_event("check", _params, socket),
    do: command(socket, NervesGate.check_firmware(), "Release check started.")

  def handle_event("prepare", %{"id" => id}, socket) do
    command(
      socket,
      NervesGate.prepare_firmware(id, socket.assigns.connection_id),
      "Firmware download started."
    )
  end

  def handle_event("install", %{"id" => id}, socket) do
    command(
      socket,
      NervesGate.install_firmware(id, socket.assigns.connection_id),
      "Pre-update checks started."
    )
  end

  def handle_event("accept", %{"id" => id}, socket) do
    actor = %{
      id: socket.assigns.connection_id,
      tailnet?: socket.assigns.tailnet_access,
      boot_id: socket.assigns.fleet.local.boot_id
    }

    command(socket, NervesGate.accept_firmware(id, actor), "Firmware acceptance started.")
  end

  def handle_event("rollback", %{"id" => id}, socket) do
    command(
      socket,
      NervesGate.rollback_firmware(id),
      "Rollback scheduled. The gateway will reboot."
    )
  end

  @impl true
  def handle_info(
        {:nerves_gate_state_changed, session, fleet},
        %{private: %{session: session}} = socket
      ) do
    {:noreply, assign(socket, fleet: fleet, firmware: firmware(fleet))}
  end

  def handle_info(
        {:DOWN, reference, :process, session, _reason},
        %{private: %{session: session, session_monitor: reference}} = socket
      ) do
    {:stop, :nerves_gate_session_stopped, socket}
  end

  defp command(socket, :ok, message), do: {:noreply, put_flash(socket, :info, message)}

  defp command(socket, {:error, reason}, _message),
    do: {:noreply, put_flash(socket, :error, error_message(reason))}

  defp firmware(fleet), do: fleet.local.state.firmware || unsupported()

  defp unsupported do
    %{
      supported: false,
      phase: :unsupported,
      current: %{},
      validation: :unsupported
    }
  end

  defp release_details(release) do
    [
      {"Version", release.version},
      {"Firmware UUID", release.uuid},
      {"System", release.system},
      {"Architecture", release.architecture},
      {"Download", format_bytes(release.size)}
    ]
  end

  defp current_details(current) do
    [
      {"Product", current(current, :product, "Unknown")},
      {"System", current(current, :system, "Unknown")},
      {"Platform", current(current, :platform, "Unknown")},
      {"Architecture", current(current, :architecture, "Unknown")},
      {"Firmware UUID", current(current, :uuid, "Unknown")},
      {"Source revision", current(current, :vcs_identifier, "Unknown")}
    ]
  end

  defp health_details(checks) when map_size(checks) == 0, do: [{"Health checks", "Starting"}]

  defp health_details(checks) do
    Enum.map(checks, fn {name, result} -> {humanize(name), health_label(result)} end)
  end

  defp phase_title(:unsupported), do: "Updates unavailable"
  defp phase_title(:idle), do: "Ready to check"
  defp phase_title(:checking), do: "Checking GitHub Releases"
  defp phase_title(:downloading), do: "Downloading to persistent storage"
  defp phase_title(:verifying), do: "Verifying signature and metadata"
  defp phase_title(:ready), do: "Verified firmware ready"
  defp phase_title(:preflight), do: "Running pre-update checks"
  defp phase_title(:installing), do: "Writing the inactive firmware slot"
  defp phase_title(:rebooting), do: "Rebooting into the selected slot"
  defp phase_title(:trial), do: "Testing unvalidated firmware"
  defp phase_title(:validating), do: "Committing firmware"
  defp phase_title(:rolling_back), do: "Restoring known-good firmware"
  defp phase_title(:failed), do: "Update stopped safely"
  defp phase_title(:booting), do: "Reading firmware state"

  defp phase_description(%{last_error: error}) when not is_nil(error),
    do: "The active firmware remains recoverable. Last result: #{humanize(error)}."

  defp phase_description(%{phase: :ready}),
    do: "The artifact is signed, compatible, and unchanged on persistent storage."

  defp phase_description(%{phase: phase}) when phase in [:installing, :rebooting],
    do: "Do not remove power intentionally. The previous active slot remains the fallback."

  defp phase_description(_firmware),
    do: "Only a verified compatible artifact can reach the platform installer."

  defp phase_tone(phase) when phase in [:idle, :ready], do: :good
  defp phase_tone(phase) when phase in [:failed, :rolling_back], do: :bad
  defp phase_tone(:unsupported), do: :neutral
  defp phase_tone(_phase), do: :warning

  defp trial_description(trial) do
    "Automatic rollback in approximately #{format_duration(trial.remaining_seconds)} unless accepted."
  end

  defp artifact_label(%{phase: :downloading}), do: "Downloading"
  defp artifact_label(%{phase: :verifying}), do: "Cryptographic verification"
  defp artifact_label(%{artifact: %{verified: true}}), do: "Verified artifact"
  defp artifact_label(_firmware), do: "Firmware artifact"

  defp available_label(nil), do: "No newer release"
  defp available_label(release), do: release.version
  defp validation_label(:validated), do: "Validated"
  defp validation_label(:trial), do: "Trial — not accepted"
  defp validation_label(:unknown), do: "Unknown"
  defp validation_label(:unsupported), do: "Unsupported"

  defp health_label(:ok), do: "OK"
  defp health_label(value), do: humanize(value)

  defp current(map, key, fallback),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || fallback

  defp format_bytes(bytes) when bytes >= 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MiB"

  defp format_bytes(bytes), do: "#{div(bytes, 1024)} KiB"

  defp format_duration(seconds) when seconds >= 60,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds), do: "#{seconds}s"

  defp error_message(reason), do: "Firmware command rejected: #{humanize(reason)}."

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp connection_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp assign_private(socket, assigns) do
    Enum.reduce(assigns, socket, fn {key, value}, socket -> put_in(socket.private[key], value) end)
  end
end
