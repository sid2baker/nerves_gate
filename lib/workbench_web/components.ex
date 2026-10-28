defmodule WorkbenchWeb.Components do
  @moduledoc "Small shared workbench components and presentation helpers."
  use Phoenix.Component
  import NervesGateWeb.CoreComponents

  attr(:section, :atom, required: true)

  def develop_navigation(assigns) do
    ~H"""
    <nav class="dev-filters" aria-label="Development workspace">
      <.link navigate="/develop/plugins" aria-current={if @section == :plugins, do: "page"}>Develop a plugin</.link>
      <.link navigate="/develop/firmware" aria-current={if @section == :firmware, do: "page"}>Build and test firmware</.link>
    </nav>
    """
  end

  attr(:source, :atom, required: true)

  def device_kind(assigns) do
    ~H"""
    <span class={["ui-badge", @source == :qemu && "dev-badge--simulated"]} data-device-kind={@source}>
      {if @source == :qemu, do: "Simulated · QEMU", else: "Physical"}
    </span>
    """
  end

  attr(:gateway, :map, required: true)

  def connection(assigns) do
    ~H"""
    <.status :if={@gateway.connected} tone="good">Connected</.status>
    <.status :if={!@gateway.connected && @gateway.last_seen} tone="warning">
      Last seen {Calendar.strftime(@gateway.last_seen, "%Y-%m-%d %H:%M:%S")} UTC
    </.status>
    <.status :if={!@gateway.connected && !@gateway.last_seen}>Never connected</.status>
    """
  end

  attr(:job, :map, required: true)
  attr(:id, :string, default: "workbench-job")

  def job(assigns) do
    ~H"""
    <div :if={@job.kind} id={@id} class="ui-stack">
      <p role="status">{job_label(@job.kind)} · {@job.status}</p>
      <div :if={@job.status == :running} class="ui-progress"></div>
      <code :if={@job.output} class="bench-output">{@job.output}</code>
      <.notice :if={@job.result && @job.status == :failed} tone="warning" role="alert">
        {@job.result}
      </.notice>
      <p :if={@job.result && @job.status != :failed} class="dev-result">{@job.result}</p>
      <p :if={@job[:recovery]} class="dev-result">
        Preserve recovery files: <code>{@job.recovery}</code>
      </p>
    </div>
    """
  end

  def job_path(%{kind: kind}) when kind in ["factory_review", "factory_provision"],
    do: "/provision"

  def job_path(%{kind: kind, subject: node})
      when kind in ["firmware_review", "firmware_update", "check"] and is_atom(node) and
             node != nil,
      do: "/devices/#{node}"

  def job_path(%{kind: kind, subject: path})
      when kind in ["test", "package", "install"] and is_binary(path),
      do: "/develop/plugins/" <> Base.url_encode64(path, padding: false)

  def job_path(_), do: "/develop/firmware"

  def job_label(nil), do: "No job"
  def job_label("check"), do: "Physical check"
  def job_label("firmware"), do: "Firmware build"
  def job_label("firmware_review"), do: "Firmware review"
  def job_label("firmware_update"), do: "Firmware update"
  def job_label("factory_review"), do: "Factory review"
  def job_label("factory_provision"), do: "Factory provisioning"
  def job_label(kind), do: String.capitalize(kind)

  def port_label(:lan1), do: "LAN1"
  def port_label(:lan2), do: "LAN2"
  def result_tone(:passed), do: "good"
  def result_tone(:succeeded), do: "good"
  def result_tone(:awaiting_confirmation), do: "warning"
  def result_tone(:failed), do: "warning"
  def result_tone(:running), do: "busy"
  def result_tone(_), do: "neutral"

  @doc "Simulator status label for a configured device id."
  def simulated_status(bench, id) do
    case bench.devices[id] do
      nil -> to_string(bench.lifecycle.status)
      %{blocked: true} -> "blocked · reset required"
      %{owner: :manual} -> "manual control"
      %{owner: nil} -> "ready"
      %{owner: run} -> "run ##{run}"
    end
  end
end
