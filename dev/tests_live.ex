defmodule NervesGateWeb.TestsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.QemuTests

  def mount(_, _, socket) do
    if connected?(socket), do: QemuTests.subscribe()
    {:ok, assign(socket, run: QemuTests.snapshot(), error: nil)}
  end

  def handle_event("run", %{"scenario" => scenario}, socket) do
    case QemuTests.run(scenario) do
      {:ok, _} -> {:noreply, assign(socket, run: QemuTests.snapshot(), error: nil)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_info({:qemu_tests, run}, socket), do: {:noreply, assign(socket, :run, run)}

  def render(assigns) do
    ~H"""
    <main class="ui-main ui-stack" id="tests">
      <.link navigate="/" class="ui-text-link">Back to Overview</.link>
      <.page_header
        title="QEMU scenarios"
        description="One disposable device. The same scenarios from the page, CLI and CI."
      />
      <p>Scenarios change settings and inject faults. Do not edit the device during a run.</p>
      <p>CLI: <code>mix test --only cable_loss</code> · all: <code>mix test</code></p>
      <p>
        Firmware is built at session startup. Restart <code>mix dev.qemu</code> to use new firmware.
      </p>
      <.notice :if={@error} tone="warning" role="alert">{@error}</.notice>
      <button
        class="ui-button"
        phx-click="run"
        phx-value-scenario="all"
        disabled={@run.status == :running}
      >Run all</button>
      <p role="status" aria-live="polite" id="run-status">Run: {@run.status} · {@run.phase}</p>
      <ul class="ui-stack" id="test-results">
        <li :for={row <- @run.rows} id={"scenario-#{row.id}"}>
          <strong>{row.name}</strong>
          — {row.status}
          <span :if={row.milliseconds}>({row.milliseconds} ms)</span>
          <button
            class="ui-button"
            phx-click="run"
            phx-value-scenario={row.id}
            disabled={@run.status == :running}
          >Run {row.id}</button>
          <pre :if={row.detail != ""}>{row.detail}</pre>
        </li>
      </ul>
      <p>Only the latest run is retained. Logs are in <code>_build/qemu-tests/</code>.</p>
    </main>
    """
  end
end
