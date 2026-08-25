defmodule NervesGateQEMUWeb.QemuLive do
  @moduledoc "Host-only QEMU test control plane."

  use NervesGateQEMUWeb, :live_view

  alias NervesGateQEMU.Fault
  alias NervesGateQEMU.Runner
  alias NervesGateQEMU.Status

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    snapshot = Status.all()

    {:ok,
     assign(socket,
       snapshot: snapshot,
       count: length(snapshot.devices),
       busy: false,
       operation: nil,
       iframe_revision: 0
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="surface-grid min-h-screen px-4 py-6 sm:px-6 lg:px-8">
      <div class="mx-auto grid max-w-[1800px] gap-6">
        <header class="flex flex-col gap-4 rounded-3xl border border-white/10 bg-zinc-950/80 p-6 shadow-2xl shadow-black/20 backdrop-blur sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="mb-2 text-xs font-bold tracking-[0.22em] text-emerald-300 uppercase">
              Host development
            </p>
            <h1 class="text-3xl font-black tracking-tight text-white sm:text-4xl">
              QEMU Test Setup
            </h1>
            <p class="mt-2 max-w-3xl text-sm leading-6 text-zinc-400">
              Manage local gateways, inject deterministic uplink disconnects, and inspect every dashboard without leaving this page.
            </p>
          </div>
          <div class="flex items-center gap-3 text-xs text-zinc-500">
            <span>Updated {Calendar.strftime(@snapshot.observed_at, "%H:%M:%S")}</span>
            <.badge tone={if(@busy, do: :warning, else: :good)}>
              {if @busy, do: @operation, else: "Ready"}
            </.badge>
          </div>
        </header>

        <.flash_group flash={@flash} />

        <.card class="grid gap-4 xl:grid-cols-[minmax(15rem,22rem)_1fr] xl:items-end">
          <form phx-submit="setup" class="grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
            <.input
              label="Machine count"
              name="topology[count]"
              type="number"
              min="1"
              max="12"
              value={@count}
              hint="Setup recreates fresh disks. Add preserves existing machines."
            />
            <.button type="submit" disabled={@busy}>Setup</.button>
          </form>

          <div class="flex flex-wrap gap-2 xl:justify-end">
            <.button tone={:secondary} phx-click="add" disabled={@busy}>Add device</.button>
            <.button tone={:secondary} phx-click="restart-all" disabled={@busy}>
              Restart all
            </.button>
            <.button tone={:secondary} phx-click="stop-all" disabled={@busy}>Stop all</.button>
            <.button tone={:danger} phx-click="reset-all" disabled={@busy}>Reset all</.button>
            <.button tone={:ghost} phx-click="heal-all" disabled={@busy}>Heal all</.button>
          </div>
        </.card>

        <div class="grid gap-6">
          <.device_card
            :for={device <- @snapshot.devices}
            device={device}
            busy={@busy}
            iframe_revision={@iframe_revision}
          />
        </div>
      </div>
    </main>
    """
  end

  attr(:device, :map, required: true)
  attr(:busy, :boolean, required: true)
  attr(:iframe_revision, :integer, required: true)

  defp device_card(assigns) do
    ~H"""
    <section class="overflow-hidden rounded-3xl border border-white/10 bg-zinc-900/75 shadow-2xl shadow-black/20">
      <div class="grid gap-5 border-b border-white/10 p-5 lg:grid-cols-[minmax(12rem,18rem)_1fr_auto] lg:items-center">
        <div>
          <div class="flex items-center gap-3">
            <span class="grid size-11 place-items-center rounded-2xl bg-emerald-400/10 text-emerald-300">
              <.icon name={:server} />
            </span>
            <div>
              <h2 class="text-xl font-black text-white">{@device.id}</h2>
              <a
                href={@device.iframe_url}
                target="_blank"
                rel="noreferrer"
                class="inline-flex items-center gap-1 font-mono text-xs text-zinc-500 hover:text-emerald-300"
              >
                {@device.iframe_url} <.icon name={:external} class="size-3.5" />
              </a>
            </div>
          </div>
        </div>

        <dl class="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
          <.metric label="VM" value={@device.vm} />
          <.metric label="Link" value={@device.link} />
          <.metric label="Internet" value={@device.internet} />
          <.metric label="Tailnet" value={@device.tailnet} />
          <.metric label="Cluster" value={@device.cluster} />
          <.metric label="Fault" value={@device.fault} />
        </dl>

        <div class="flex flex-wrap gap-2 lg:justify-end">
          <.button
            tone={:secondary}
            phx-click="disconnect"
            phx-value-device={@device.id}
            disabled={@busy or @device.vm != :running or @device.link == :down}
          >
            Disconnect
          </.button>
          <.button
            tone={:primary}
            phx-click="heal"
            phx-value-device={@device.id}
            disabled={@busy or @device.vm != :running or @device.link == :up}
          >
            Heal
          </.button>
          <.button
            tone={:ghost}
            phx-click="restart"
            phx-value-device={@device.id}
            disabled={@busy}
          >
            Restart
          </.button>
          <.button
            tone={:danger}
            phx-click="remove"
            phx-value-device={@device.id}
            disabled={@busy}
          >
            Remove
          </.button>
        </div>
      </div>

      <div class="grid gap-3 border-b border-white/10 bg-zinc-950/35 px-5 py-3 text-xs text-zinc-500 sm:grid-cols-3">
        <span>Tailnet IP: <strong class="font-mono text-zinc-300">{@device.tailnet_ip || "—"}</strong></span>
        <span>
          Replicas:
          <strong class="text-zinc-300">{@device.connected_replicas}/{@device.replicas} connected</strong>
        </span>
        <span>
          Alarms: <strong class={if @device.alarms == [], do: "text-emerald-300", else: "text-amber-200"}>{length(@device.alarms)}</strong>
        </span>
      </div>

      <details :if={@device.vm == :running} open class="group bg-black/30">
        <summary class="flex cursor-pointer items-center justify-between border-b border-white/5 px-5 py-3 text-xs font-bold tracking-wider text-zinc-500 uppercase hover:text-zinc-300">
          Embedded dashboard
          <span class="normal-case tracking-normal text-zinc-600 group-open:hidden">Expand</span>
          <span class="hidden normal-case tracking-normal text-zinc-600 group-open:inline">Collapse</span>
        </summary>
        <div class="p-3 sm:p-4">
          <iframe
            id={"qemu-frame-#{@device.slug}-#{@iframe_revision}"}
            src={@device.iframe_url}
            title={"#{@device.id} NervesGate dashboard"}
            loading="lazy"
            referrerpolicy="no-referrer"
            class="h-[44rem] w-full rounded-2xl border border-white/10 bg-zinc-950"
          >
          </iframe>
        </div>
      </details>

      <div :if={@device.vm != :running} class="grid min-h-52 place-items-center bg-black/30 p-8 text-center">
        <div>
          <.icon name={:alert} class="mx-auto mb-3 size-7 text-zinc-600" />
          <p class="font-semibold text-zinc-400">Dashboard unavailable while the VM is stopped.</p>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :atom, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="grid gap-1 rounded-xl border border-white/5 bg-black/15 px-3 py-2">
      <dt class="text-[0.65rem] font-bold tracking-wider text-zinc-600 uppercase">{@label}</dt>
      <dd><.badge tone={status_tone(@value)}>{@value |> to_string() |> String.replace("_", " ")}</.badge></dd>
    </div>
    """
  end

  @impl true
  def handle_event("setup", %{"topology" => %{"count" => count}}, socket) do
    case Integer.parse(count) do
      {parsed, ""} -> start_operation(socket, "Setting up", fn -> Runner.setup(count: parsed) end)
      _invalid -> {:noreply, put_flash(socket, :error, "Enter a valid machine count.")}
    end
  end

  def handle_event("add", _params, socket),
    do: start_operation(socket, "Adding device", &Runner.add/0)

  def handle_event("restart-all", _params, socket),
    do: start_operation(socket, "Restarting all", &Runner.restart/0)

  def handle_event("stop-all", _params, socket),
    do: start_operation(socket, "Stopping all", &Runner.stop/0)

  def handle_event("reset-all", _params, socket),
    do: start_operation(socket, "Resetting all", &Runner.reset/0)

  def handle_event("heal-all", _params, socket),
    do: start_operation(socket, "Healing all", &Fault.heal_all/0)

  def handle_event("disconnect", %{"device" => id}, socket),
    do: start_operation(socket, "Disconnecting #{id}", fn -> Fault.link_down(id) end)

  def handle_event("heal", %{"device" => id}, socket),
    do: start_operation(socket, "Healing #{id}", fn -> Fault.heal(id) end)

  def handle_event("restart", %{"device" => id}, socket),
    do: start_operation(socket, "Restarting #{id}", fn -> Runner.restart(id) end)

  def handle_event("remove", %{"device" => id}, socket),
    do: start_operation(socket, "Removing #{id}", fn -> Runner.remove(id) end)

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_async(:operation, {:ok, result}, socket) do
    socket = assign(socket, busy: false, operation: nil)

    case result do
      :ok -> {:noreply, operation_succeeded(socket)}
      {:ok, _value} -> {:noreply, operation_succeeded(socket)}
      {:error, reason} -> {:noreply, put_flash(refresh(socket), :error, format_error(reason))}
    end
  end

  def handle_async(:operation, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(busy: false, operation: nil)
     |> refresh()
     |> put_flash(:error, "Operation crashed: #{inspect(reason)}")}
  end

  defp start_operation(%{assigns: %{busy: true}} = socket, _label, _function),
    do: {:noreply, socket}

  defp start_operation(socket, label, function) do
    socket = socket |> assign(busy: true, operation: label) |> clear_flash()
    {:noreply, start_async(socket, :operation, function)}
  end

  defp operation_succeeded(socket) do
    socket
    |> update(:iframe_revision, &(&1 + 1))
    |> refresh()
    |> put_flash(:info, "QEMU operation completed.")
  end

  defp refresh(socket) do
    snapshot = Status.all()
    assign(socket, snapshot: snapshot, count: length(snapshot.devices))
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

  defp format_error({:firmware_not_found, path}),
    do: "Firmware not found at #{path}. Run MIX_TARGET=x86_64 mix firmware first."

  defp format_error(:netem_not_configured),
    do: "Loss and latency require the upcoming TAP/netem host network layer."

  defp format_error(reason), do: inspect(reason)

  defp status_tone(value) when value in [:running, :up, :online, :none], do: :good
  defp status_tone(value) when value in [:disabled, :unconfigured], do: :neutral

  defp status_tone(value)
       when value in [
              :paused,
              :unknown,
              :applying,
              :backoff,
              :needs_auth,
              :connecting,
              :observing,
              :reconciling,
              :blocked
            ],
       do: :warning

  defp status_tone(_value), do: :bad
end
