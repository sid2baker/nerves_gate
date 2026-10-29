defmodule NervesGateWeb.IOLive do
  @moduledoc """
  Readings and output Desires registered by plugins, with Status and manual control.
  Reads go through `NervesGate.IO.Manual` so `owned?` means manual control; all
  validation stays in `NervesGate.IO`. Freshness depends on elapsed time, not only on
  changes, so the page re-reads once a second. Drafts stay separate from that read.
  """
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.IO.Manual

  on_mount({NervesGateWeb.Observations, :status})

  @poll_ms 1_000

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)
    {:ok, socket |> assign(drafts: %{}) |> read()}
  end

  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, read(socket)}
  end

  def handle_event("claim", %{"id" => id}, socket),
    do:
      command(
        socket,
        Manual.claim(id),
        "Manual control taken. No value is set until you set one."
      )

  def handle_event("draft", %{"output" => id, "value" => value}, socket),
    do: {:noreply, update(socket, :drafts, &Map.put(&1, id, value))}

  def handle_event("set", %{"output" => id, "value" => text}, socket) do
    with %{definition: definition} <- output(socket, id),
         {:ok, value} <- parse(definition.type, text) do
      socket = update(socket, :drafts, &Map.delete(&1, id))

      command(
        socket,
        Manual.set(id, value),
        "Desired value stored. The plugin decides how the equipment follows; Status shows what the evidence says."
      )
    else
      nil -> {:noreply, put_flash(socket, :error, "This output is not defined.")}
      :error -> {:noreply, put_flash(socket, :error, "Enter a #{type_name(output(socket, id))}.")}
    end
  end

  def handle_event("release", %{"id" => id}, socket),
    do:
      command(
        socket,
        Manual.release(id),
        "Manual control released. The target was cleared; the plugin's release behaviour applies."
      )

  defp command(socket, result, success) do
    socket = clear_flash(socket)

    case result do
      :ok -> {:noreply, socket |> put_flash(:info, success) |> read()}
      {:error, error} -> {:noreply, socket |> put_flash(:error, error.message) |> read()}
    end
  end

  defp read(socket),
    do: assign(socket, io: Manual.status(), now: System.monotonic_time(:millisecond))

  defp output(%{assigns: %{io: %{outputs: outputs}}}, id), do: Enum.find(outputs, &(&1.id == id))
  defp output(_, _), do: nil

  @doc false
  def parse(:boolean, "true"), do: {:ok, true}
  def parse(:boolean, "false"), do: {:ok, false}
  def parse(:integer, text), do: whole(Integer.parse(String.trim(text)))
  def parse(:float, text), do: whole(Float.parse(String.trim(text)))
  def parse(:string, text) when text != "", do: {:ok, text}
  def parse(_, _), do: :error

  defp whole({value, ""}), do: {:ok, value}
  defp whole(_), do: :error

  def render(assigns) do
    ~H"""
    <.page_header
      title="I/O"
      description="Values plugins observe, and targets they keep equipment at."
    />
    <.notice icon="info">
      Setting a desired value only stores the target. The owning plugin decides how and
      whether the equipment follows; Status shows whether its evidence agrees. Releasing
      clears the target; what the equipment then does is the plugin's declared behaviour.
    </.notice>
    <.notice :if={match?({:error, _}, @io)} tone="warning" role="alert" id="io-unavailable">
      I/O is unavailable. {elem(@io, 1).message}
    </.notice>
    <div :if={is_map(@io)} class="ui-stack">
      <.panel title="Inputs" icon="display" id="io-inputs">
        <p :if={@io.inputs == []} class="ui-help">No plugin has registered an input.</p>
        <ul class="ui-io-list">
          <li :for={input <- @io.inputs} id={dom_id("io-input", input.id)}>
            <div>
              <strong>{input.definition.id}</strong>
              <code>{input.id}</code>
              <span class="ui-muted">{describe(input.definition)}</span>
            </div>
            <div class="ui-io-value">
              <strong>{observed(input)}</strong>
              <.status tone={tone(input)}>{state(input)}</.status>
              <span :if={input.reading} class="ui-muted">{age(input.reading, @now)}</span>
            </div>
          </li>
        </ul>
      </.panel>
      <.panel title="Outputs" icon="port" id="io-outputs">
        <p :if={@io.outputs == []} class="ui-help">No plugin has registered an output.</p>
        <ul class="ui-io-list">
          <li :for={output <- @io.outputs} id={dom_id("io-output", output.id)}>
            <div>
              <strong>{output.definition.id}</strong>
              <code>{output.id}</code>
              <span class="ui-muted">{describe(output.definition)}</span>
            </div>
            <div class="ui-io-value">
              <strong>Target: {target(output)}</strong>
              <.status tone={writer_tone(output)}>{writer(output)}</.status>
              <span id={dom_id("io-status", output.id)}>
                <.status tone={status_tone(output.status.state)}>
                  {status_name(output.status.state)}
                </.status>
              </span>
            </div>
            <details class="ui-io-details" id={dom_id("io-evidence", output.id)}>
              <summary>{output.status.reason}</summary>
              <dl>
                <dt>Apply</dt>
                <dd>{applied(output.status.applied)}</dd>
                <div :for={entry <- output.status.evidence} class="ui-io-pair">
                  <dt>{String.capitalize(to_string(entry.role))} · <code>{entry.input}</code></dt>
                  <dd>{evidence_state(entry.state)}</dd>
                </div>
                <dt>On release</dt>
                <dd>{on_release(output.definition)}</dd>
              </dl>
            </details>
            <div class="ui-io-controls">
              <.button
                :if={!output.claimed?}
                id={dom_id("io-claim", output.id)}
                variant="secondary"
                phx-click="claim"
                phx-value-id={output.id}
                disabled={!output.available?}
              >Take manual control</.button>
              <.form
                :if={output.owned?}
                for={%{}}
                id={dom_id("io-set", output.id)}
                class="ui-io-controls"
                phx-change="draft"
                phx-submit="set"
              >
                <input type="hidden" name="output" value={output.id} />
                <label for={dom_id("io-value", output.id)}>Desired value</label>
                <select
                  :if={output.definition.type == :boolean}
                  id={dom_id("io-value", output.id)}
                  name="value"
                >
                  <option
                    :for={choice <- ["true", "false"]}
                    value={choice}
                    selected={draft(@drafts, output) == choice}
                  >
                    {choice}
                  </option>
                </select>
                <input
                  :if={output.definition.type != :boolean}
                  type="text"
                  id={dom_id("io-value", output.id)}
                  name="value"
                  value={draft(@drafts, output)}
                  inputmode={if output.definition.type in [:integer, :float], do: "decimal"}
                  autocomplete="off"
                />
                <.button type="submit" disabled={!output.available?}>Set target</.button>
              </.form>
              <.button
                :if={output.owned?}
                id={dom_id("io-release", output.id)}
                variant="quiet"
                phx-click="release"
                phx-value-id={output.id}
              >Release</.button>
            </div>
          </li>
        </ul>
      </.panel>
    </div>
    """
  end

  # Full IDs are lowercase segments joined by dots, so this mapping is unambiguous.
  defp dom_id(prefix, id), do: prefix <> "-" <> String.replace(id, ".", "-")

  defp describe(definition) do
    limits =
      case Map.take(Map.from_struct(definition), [:min, :max]) do
        %{min: nil, max: nil} -> nil
        %{min: min, max: max} -> "#{min || "−∞"} – #{max || "∞"}"
        _ -> nil
      end

    [Atom.to_string(definition.type), definition.unit, limits]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp observed(%{reading: nil}), do: "No value yet"

  defp observed(%{reading: %{quality: :good, value: value}, definition: d}),
    do: format(value, d)

  defp observed(_), do: "—"

  defp target(%{desired: nil}), do: "none"
  defp target(%{desired: value, definition: definition}), do: format(value, definition)

  defp format(value, %{unit: nil}), do: to_string(value)
  defp format(value, %{unit: unit}), do: "#{value} #{unit}"

  defp state(%{available?: false}), do: "Plugin not running"
  defp state(%{reading: nil}), do: "No reading"
  defp state(%{reading: %{quality: :invalid}}), do: "Invalid"
  defp state(%{reading: %{quality: :unknown}}), do: "Unknown"
  defp state(%{stale?: true}), do: "Stale"
  defp state(_), do: "Fresh"

  defp tone(input) do
    case state(input) do
      "Fresh" -> "good"
      "No reading" -> "neutral"
      _ -> "warning"
    end
  end

  defp writer(%{available?: false}), do: "Plugin not running"
  defp writer(%{owned?: true}), do: "Manual control"
  defp writer(%{claimed?: true}), do: "Other writer"
  defp writer(_), do: "Free"

  defp writer_tone(output) do
    case writer(output) do
      "Manual control" -> "busy"
      "Free" -> "neutral"
      _ -> "warning"
    end
  end

  defp status_name(:confirmed), do: "Confirmed"
  defp status_name(:pending), do: "Pending"
  defp status_name(:mismatch), do: "Mismatch"
  defp status_name(:unknown), do: "Unknown"

  defp status_tone(:confirmed), do: "good"
  defp status_tone(:pending), do: "busy"
  defp status_tone(:mismatch), do: "warning"
  defp status_tone(:unknown), do: "neutral"

  defp applied(nil), do: "No outcome for this target yet"
  defp applied(:applied), do: "Applied (the operation appeared successful)"
  defp applied(:unknown), do: "Unknown (it may or may not have happened)"
  defp applied(:failed), do: "Failed"

  defp evidence_state(:confirmed), do: "Agrees"
  defp evidence_state(:contradicted), do: "Disagrees"
  defp evidence_state(:pending), do: "Waiting"
  defp evidence_state(:stale), do: "Stale or not good"
  defp evidence_state(:unknown), do: "No usable evidence"

  defp on_release(%{on_release: nil}), do: "Not declared by the plugin"
  defp on_release(%{on_release: :hold}), do: "Plugin holds the last value"

  defp on_release(%{on_release: {:value, value}} = definition),
    do: "Plugin sets #{format(value, definition)}"

  defp age(%{received_at_ms: at}, now) do
    seconds = max(0, div(now - at, 1_000))
    if seconds < 1, do: "just now", else: "#{seconds} s ago"
  end

  defp draft(drafts, %{id: id, desired: desired}),
    do: Map.get_lazy(drafts, id, fn -> if desired == nil, do: "", else: to_string(desired) end)

  defp type_name(%{definition: %{type: :boolean}}), do: "true or false"
  defp type_name(%{definition: %{type: :integer}}), do: "whole number"
  defp type_name(%{definition: %{type: :float}}), do: "number"
  defp type_name(_), do: "non-empty value"
end
