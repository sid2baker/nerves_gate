defmodule NervesGate.Firmware do
  @moduledoc "Owns the signed, recoverable firmware-update transaction across reboots."

  alias NervesGate.Firmware.{Artifact, Clock, Health, Persistence, Release, Status}
  alias NervesGate.FSM.{Diagnostics, Effect}
  alias NervesGate.Gateway.Configuration
  alias NervesGate.Storage

  @fsm """
  [*] --> booting : boot
  booting --> unsupported : activate
  booting --> checking : activate
  booting --> ready : activate
  booting --> rebooting : activate
  booting --> trial : activate
  booting --> rolling_back : activate
  unsupported --> unsupported : check
  unsupported --> unsupported : tick
  checking --> checking : check
  checking --> checking : check_completed
  checking --> idle : check_completed
  checking --> ready : check_completed
  checking --> failed : check_completed
  idle --> checking : check
  idle --> downloading : prepare
  idle --> idle : prepare
  idle --> checking : tick
  idle --> idle : tick
  ready --> checking : check
  ready --> downloading : prepare
  ready --> ready : prepare
  ready --> preflight : install
  ready --> ready : install
  ready --> checking : tick
  ready --> ready : tick
  failed --> checking : check
  failed --> downloading : prepare
  failed --> failed : prepare
  failed --> checking : tick
  failed --> failed : tick
  downloading --> downloading : download_progressed
  downloading --> verifying : download_completed
  downloading --> failed : download_completed
  verifying --> ready : verification_completed
  verifying --> failed : verification_completed
  preflight --> installing : preflight_completed
  preflight --> ready : preflight_completed
  installing --> rebooting : installation_completed
  installing --> ready : installation_completed
  installing --> failed : installation_completed
  rebooting --> rebooting : reboot_completed
  rebooting --> rebooting : tick
  trial --> trial : health_completed
  trial --> rolling_back : health_completed
  trial --> trial : tick
  trial --> rolling_back : tick
  trial --> validating : accept
  trial --> trial : accept
  trial --> rolling_back : rollback
  trial --> trial : rollback
  validating --> idle : validation_completed
  validating --> trial : validation_completed
  rolling_back --> rebooting : rollback_completed
  rolling_back --> idle : rollback_completed
  rolling_back --> rolling_back : rollback_completed
  rolling_back --> rolling_back : tick
  booting --> [*] : terminate
  unsupported --> [*] : terminate
  checking --> [*] : terminate
  idle --> [*] : terminate
  downloading --> [*] : terminate
  verifying --> [*] : terminate
  ready --> [*] : terminate
  preflight --> [*] : terminate
  installing --> [*] : terminate
  rebooting --> [*] : terminate
  trial --> [*] : terminate
  validating --> [*] : terminate
  rolling_back --> [*] : terminate
  failed --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @default_check_interval :timer.hours(6)
  @default_trial_timeout :timer.minutes(15)
  @default_stable_window :timer.minutes(1)
  @default_health_grace :timer.minutes(2)

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    configured = Application.get_env(:nerves_gate, :firmware, [])
    options = Keyword.merge(configured, options)
    root = Keyword.get(options, :root, Storage.root())
    platform = Keyword.get(options, :platform, NervesGate.Firmware.Platform.Host)
    platform_options = Keyword.get(options, :platform_options, options)
    {report, platform_error} = platform_report(platform, platform_options)
    {journal, journal_error} = journal(root)
    boot_id = Keyword.get_lazy(options, :system_boot_id, &Clock.system_boot_id/0)
    journal = normalize_journal(journal, report, root)

    now = monotonic(options)

    {initial_state, effect, journal, selected, artifact_path} =
      initial_state(report, journal, root, boot_id, now, options)

    trial_deadline = trial_deadline(initial_state, now, options)

    Diagnostics.new(%{
      owner: __MODULE__,
      desired: nil,
      observed: report.current,
      root: root,
      platform: platform,
      platform_options: platform_options,
      platform_report: report,
      release_source:
        Keyword.get(options, :release_source, NervesGate.Firmware.ReleaseSource.GitHub),
      release_options: Keyword.get(options, :release_options, options),
      artifact: Keyword.get(options, :artifact, Artifact),
      artifact_options: Keyword.get(options, :artifact_options, options),
      health: Keyword.get(options, :health, Health),
      health_provider:
        Keyword.get(options, :health_provider, fn ->
          Health.post_boot(NervesGate.DeviceState.state())
        end),
      preflight_provider:
        Keyword.get(options, :preflight_provider, fn release, platform_report ->
          if Configuration.busy?() do
            {:error, %{operations: :configuration_change_in_progress}}
          else
            Health.preflight(
              NervesGate.DeviceState.state(),
              platform_report,
              release,
              root,
              options
            )
          end
        end),
      publisher: Keyword.get(options, :publisher, &publish/1),
      monotonic: Keyword.get(options, :monotonic, &Clock.monotonic_ms/0),
      uptime: Keyword.get(options, :uptime, &Clock.uptime_ms/0),
      device_boot_id: Keyword.get_lazy(options, :device_boot_id, &device_boot_id/0),
      system_boot_id: boot_id,
      initial_state: initial_state,
      available: nil,
      selected: selected,
      artifact_path: artifact_path,
      artifact_metadata: nil,
      journal: journal,
      source_connection: journal && journal.source_connection,
      progress_bytes: artifact_size(artifact_path),
      health_checks: %{},
      healthy_since: nil,
      unhealthy_since: nil,
      ever_healthy: false,
      confirmable: false,
      trial_deadline: trial_deadline,
      trial_timeout: Keyword.get(options, :trial_timeout, @default_trial_timeout),
      stable_window: Keyword.get(options, :stable_window, @default_stable_window),
      health_grace: Keyword.get(options, :health_grace, @default_health_grace),
      check_interval: Keyword.get(options, :check_interval, @default_check_interval),
      next_check_at: now,
      last_checked_at: nil,
      check_pending: false,
      effect_timeout: Keyword.get(options, :effect_timeout, :timer.minutes(20)),
      effect: effect,
      rollback_kind: rollback_kind(effect),
      reply: nil,
      last_error: platform_error || journal_error
    })
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} -> public_status(state, payload)
      nil -> unsupported_status()
    end
  end

  @spec busy?(GenServer.server()) :: boolean()
  def busy?(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state} ->
        state in [:preflight, :installing, :rebooting, :trial, :validating, :rolling_back]

      nil ->
        false
    end
  end

  @spec check(GenServer.server()) :: :ok | {:error, term()}
  def check(server \\ __MODULE__), do: request(server, :check, %{})

  @spec prepare(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def prepare(release_id, connection_id, server \\ __MODULE__),
    do: request(server, :prepare, %{release_id: release_id, connection_id: connection_id})

  @spec install(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def install(release_id, connection_id, server \\ __MODULE__),
    do: request(server, :install, %{release_id: release_id, connection_id: connection_id})

  @spec accept(String.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def accept(trial_id, connection, server \\ __MODULE__),
    do: request(server, :accept, %{trial_id: trial_id, connection: connection})

  @spec rollback(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def rollback(trial_id, server \\ __MODULE__),
    do: request(server, :rollback, %{trial_id: trial_id})

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload) do
    finish(:*, :boot, :booting, payload)
  end

  def on_transition(:booting, :activate, _event_payload, payload) do
    finish(:booting, :activate, payload.initial_state, payload)
  end

  def on_transition(:unsupported, :check, command, payload),
    do:
      finish(
        :unsupported,
        :check,
        :unsupported,
        result(payload, command.id, {:error, :unsupported})
      )

  def on_transition(state, :check, command, payload) when state in [:idle, :ready, :failed] do
    payload =
      payload
      |> Map.put(:effect, %{kind: :discovery, ref: make_ref(), return_state: check_return(state)})
      |> result(command.id, :ok)

    finish(state, :check, :checking, payload)
  end

  def on_transition(:checking, :check, command, payload) do
    payload = payload |> Map.put(:check_pending, true) |> result(command.id, :ok)
    finish(:checking, :check, :checking, payload)
  end

  def on_transition(
        :checking,
        :check_completed,
        {ref, _outcome},
        %{
          effect: %{ref: ref, return_state: return_state},
          check_pending: true
        } = payload
      ) do
    effect = %{kind: :discovery, ref: make_ref(), return_state: return_state}
    payload = %{payload | effect: effect, check_pending: false}
    finish(:checking, :check_completed, :checking, payload)
  end

  def on_transition(:checking, :check_completed, {ref, outcome}, %{effect: %{ref: ref}} = payload) do
    return_state = payload.effect.return_state

    payload = %{
      payload
      | effect: nil,
        last_checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    complete_check(return_state, outcome, payload)
  end

  def on_transition(state, :prepare, command, payload) when state in [:idle, :ready, :failed] do
    cond do
      is_nil(payload.available) or payload.available.id != command.release_id ->
        finish(
          state,
          :prepare,
          state,
          result(payload, command.id, {:error, :release_unavailable})
        )

      ((state == :ready and payload.selected) && payload.selected.id == command.release_id) and
          File.regular?(payload.artifact_path) ->
        finish(:ready, :prepare, :ready, result(payload, command.id, :ok))

      true ->
        effect = %{kind: :download, ref: make_ref(), release: payload.available}

        payload =
          payload
          |> Map.merge(%{
            selected: payload.available,
            artifact_path: nil,
            source_connection: command.connection_id,
            progress_bytes: 0,
            effect: effect,
            last_error: nil
          })
          |> result(command.id, :ok)

        finish(state, :prepare, :downloading, payload)
    end
  end

  def on_transition(
        :downloading,
        :download_progressed,
        {ref, bytes},
        %{effect: %{ref: ref}} = payload
      ) do
    finish(:downloading, :download_progressed, :downloading, %{payload | progress_bytes: bytes})
  end

  def on_transition(
        :downloading,
        :download_completed,
        {ref, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    payload = %{payload | effect: nil}

    case returned(outcome) do
      {:ok, {:ok, path}} ->
        effect = %{kind: :verification, ref: make_ref(), release: payload.selected, path: path}

        finish(:downloading, :download_completed, :verifying, %{
          payload
          | effect: effect,
            artifact_path: path
        })

      {:ok, {:error, reason}} ->
        fail(:downloading, :download_completed, payload, reason)

      {:error, reason} ->
        fail(:downloading, :download_completed, payload, reason)
    end
  end

  def on_transition(
        :verifying,
        :verification_completed,
        {ref, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    payload = %{payload | effect: nil}

    case returned(outcome) do
      {:ok, {:ok, metadata, journal}} ->
        finish(
          :verifying,
          :verification_completed,
          :ready,
          %{payload | artifact_metadata: metadata, journal: journal, last_error: nil}
        )

      {:ok, {:error, reason}} ->
        fail(:verifying, :verification_completed, payload, reason)

      {:error, reason} ->
        fail(:verifying, :verification_completed, payload, reason)
    end
  end

  def on_transition(:ready, :install, command, payload) do
    cond do
      is_nil(payload.selected) or payload.selected.id != command.release_id ->
        finish(
          :ready,
          :install,
          :ready,
          result(payload, command.id, {:error, :release_unavailable})
        )

      not File.regular?(payload.artifact_path) ->
        finish(
          :ready,
          :install,
          :ready,
          result(payload, command.id, {:error, :artifact_unavailable})
        )

      true ->
        effect = %{kind: :preflight, ref: make_ref(), release: payload.selected}

        payload =
          payload
          |> Map.put(:effect, effect)
          |> Map.put(:source_connection, command.connection_id)
          |> result(command.id, :ok)

        finish(:ready, :install, :preflight, payload)
    end
  end

  def on_transition(
        :preflight,
        :preflight_completed,
        {ref, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    payload = %{payload | effect: nil}

    case returned(outcome) do
      {:ok, {:ok, report, checks}} ->
        effect = %{kind: :installation, ref: make_ref()}

        finish(
          :preflight,
          :preflight_completed,
          :installing,
          %{
            payload
            | effect: effect,
              platform_report: report,
              health_checks: checks,
              last_error: nil
          }
        )

      {:ok, {:error, checks}} when is_map(checks) ->
        finish(
          :preflight,
          :preflight_completed,
          :ready,
          %{payload | health_checks: checks, last_error: :preflight_failed}
        )

      {:ok, {:error, reason}} ->
        finish(:preflight, :preflight_completed, :ready, %{
          payload
          | last_error: public_error(reason)
        })

      {:error, reason} ->
        finish(:preflight, :preflight_completed, :ready, %{
          payload
          | last_error: public_error(reason)
        })
    end
  end

  def on_transition(
        :installing,
        :installation_completed,
        {ref, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    payload = %{payload | effect: nil}

    case returned(outcome) do
      {:ok, {:ok, journal}} ->
        effect = %{kind: :reboot, ref: make_ref()}

        finish(:installing, :installation_completed, :rebooting, %{
          payload
          | journal: journal,
            effect: effect
        })

      {:ok, {:error, reason}} ->
        finish(:installing, :installation_completed, :ready, %{
          payload
          | last_error: public_error(reason)
        })

      {:error, reason} ->
        finish(:installing, :installation_completed, :ready, %{
          payload
          | last_error: public_error(reason)
        })
    end
  end

  def on_transition(
        :rebooting,
        :reboot_completed,
        {ref, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    error =
      case returned(outcome) do
        {:ok, :ok} -> :reboot_did_not_restart
        {:ok, {:error, reason}} -> public_error(reason)
        {:error, reason} -> public_error(reason)
      end

    finish(:rebooting, :reboot_completed, :rebooting, %{payload | effect: nil, last_error: error})
  end

  def on_transition(:trial, :accept, command, payload) do
    case acceptance_error(command, payload) do
      nil ->
        effect = %{kind: :validation, ref: make_ref()}
        payload = payload |> Map.put(:effect, effect) |> result(command.id, :ok)
        finish(:trial, :accept, :validating, payload)

      error ->
        finish(:trial, :accept, :trial, result(payload, command.id, {:error, error}))
    end
  end

  def on_transition(:trial, :rollback, command, payload) do
    if trial_id(payload) == command.trial_id do
      payload = payload |> begin_rollback(:requested) |> result(command.id, :ok)
      finish(:trial, :rollback, :rolling_back, payload)
    else
      finish(:trial, :rollback, :trial, result(payload, command.id, {:error, :trial_mismatch}))
    end
  end

  def on_transition(:trial, :health_completed, {ref, outcome}, %{effect: %{ref: ref}} = payload) do
    payload = %{payload | effect: nil}
    now = monotonic(payload)

    checks =
      case returned(outcome) do
        {:ok, value} when is_map(value) -> value
        _error -> %{health_observation: :unavailable}
      end

    payload = update_health(payload, checks, now)

    if rollback_required?(payload, now) do
      finish(:trial, :health_completed, :rolling_back, begin_rollback(payload, :health_failed))
    else
      finish(:trial, :health_completed, :trial, payload)
    end
  end

  def on_transition(
        :validating,
        :validation_completed,
        {ref, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    payload = %{payload | effect: nil}

    case returned(outcome) do
      {:ok, {:ok, report}} ->
        payload =
          reset_transaction(%{payload | platform_report: report, observed: report.current})

        finish(:validating, :validation_completed, :idle, %{
          payload
          | next_check_at: monotonic(payload)
        })

      {:ok, {:error, reason}} ->
        finish(:validating, :validation_completed, :trial, %{
          payload
          | last_error: public_error(reason)
        })

      {:error, reason} ->
        finish(:validating, :validation_completed, :trial, %{
          payload
          | last_error: public_error(reason)
        })
    end
  end

  def on_transition(
        :rolling_back,
        :rollback_completed,
        {ref, kind, outcome},
        %{effect: %{ref: ref}} = payload
      ) do
    payload = %{payload | effect: nil}

    case {kind, returned(outcome)} do
      {:synchronize, {:ok, {:ok, report}}} ->
        payload =
          reset_transaction(%{payload | platform_report: report, observed: report.current})

        finish(:rolling_back, :rollback_completed, :idle, %{
          payload
          | next_check_at: monotonic(payload)
        })

      {_kind, {:ok, {:ok, journal}}} ->
        effect = %{kind: :reboot, ref: make_ref()}

        finish(:rolling_back, :rollback_completed, :rebooting, %{
          payload
          | journal: journal,
            effect: effect
        })

      {_kind, {:ok, {:error, reason}}} ->
        finish(:rolling_back, :rollback_completed, :rolling_back, %{
          payload
          | last_error: public_error(reason)
        })

      {_kind, {:error, reason}} ->
        finish(:rolling_back, :rollback_completed, :rolling_back, %{
          payload
          | last_error: public_error(reason)
        })
    end
  end

  def on_transition(state, :tick, _event_payload, payload)
      when state in [:idle, :ready, :failed] do
    if is_nil(payload.effect) and monotonic(payload) >= payload.next_check_at do
      effect = %{kind: :discovery, ref: make_ref(), return_state: check_return(state)}
      finish(state, :tick, :checking, %{payload | effect: effect})
    else
      finish(state, :tick, state, payload)
    end
  end

  def on_transition(:trial, :tick, _event_payload, payload) do
    cond do
      payload.effect ->
        finish(:trial, :tick, :trial, payload)

      monotonic(payload) >= payload.trial_deadline ->
        finish(:trial, :tick, :rolling_back, begin_rollback(payload, :confirmation_timeout))

      true ->
        effect = %{kind: :health, ref: make_ref()}
        finish(:trial, :tick, :trial, %{payload | effect: effect})
    end
  end

  def on_transition(:rolling_back, :tick, _event_payload, %{effect: nil} = payload) do
    finish(
      :rolling_back,
      :tick,
      :rolling_back,
      begin_rollback(payload, payload.rollback_kind || :requested)
    )
  end

  def on_transition(:rolling_back, :tick, _event_payload, payload),
    do: finish(:rolling_back, :tick, :rolling_back, payload)

  def on_transition(:rebooting, :tick, _event_payload, %{effect: nil} = payload) do
    finish(:rebooting, :tick, :rebooting, %{payload | effect: %{kind: :reboot, ref: make_ref()}})
  end

  def on_transition(state, :tick, _event_payload, payload),
    do: finish(state, :tick, state, payload)

  @impl Finitomata
  def on_timer(:booting, %Finitomata.State{payload: payload}),
    do: {:transition, :activate, payload}

  def on_timer(_state, %Finitomata.State{payload: payload}), do: {:transition, :tick, payload}

  @doc false
  def after_transition(state, payload) do
    payload.publisher.(public_status(state, payload))
    if state != :booting, do: maybe_start_effect(payload)
  end

  defp maybe_start_effect(%{effect: %{kind: :discovery, ref: ref}} = payload) do
    start_effect(
      payload,
      ref,
      fn ->
        payload.release_source.latest(payload.platform_report.current, payload.release_options)
      end,
      fn ref, outcome -> {:check_completed, {ref, outcome}} end
    )
  end

  defp maybe_start_effect(%{effect: %{kind: :download, ref: ref, release: release}} = payload) do
    owner = self()

    start_effect(
      payload,
      ref,
      fn ->
        progress = fn bytes -> GenServer.cast(owner, {:download_progressed, {ref, bytes}}) end
        payload.artifact.download(release, payload.root, progress, payload.artifact_options)
      end,
      fn ref, outcome -> {:download_completed, {ref, outcome}} end
    )
  end

  defp maybe_start_effect(
         %{effect: %{kind: :verification, ref: ref, release: release, path: path}} = payload
       ) do
    start_effect(payload, ref, fn -> verification_work(payload, release, path) end, fn ref,
                                                                                       outcome ->
      {:verification_completed, {ref, outcome}}
    end)
  end

  defp maybe_start_effect(%{effect: %{kind: :preflight, ref: ref, release: release}} = payload) do
    start_effect(payload, ref, fn -> preflight_work(payload, release) end, fn ref, outcome ->
      {:preflight_completed, {ref, outcome}}
    end)
  end

  defp maybe_start_effect(%{effect: %{kind: :installation, ref: ref}} = payload) do
    start_effect(payload, ref, fn -> installation_work(payload) end, fn ref, outcome ->
      {:installation_completed, {ref, outcome}}
    end)
  end

  defp maybe_start_effect(%{effect: %{kind: :health, ref: ref}} = payload) do
    start_effect(payload, ref, payload.health_provider, fn ref, outcome ->
      {:health_completed, {ref, outcome}}
    end)
  end

  defp maybe_start_effect(%{effect: %{kind: :validation, ref: ref}} = payload) do
    start_effect(payload, ref, fn -> validation_work(payload) end, fn ref, outcome ->
      {:validation_completed, {ref, outcome}}
    end)
  end

  defp maybe_start_effect(%{effect: %{kind: kind, ref: ref}} = payload)
       when kind in [:rollback, :synchronize] do
    start_effect(payload, ref, fn -> rollback_work(payload, kind) end, fn ref, outcome ->
      {:rollback_completed, {ref, kind, outcome}}
    end)
  end

  defp maybe_start_effect(%{effect: %{kind: :reboot, ref: ref}} = payload) do
    start_effect(
      payload,
      ref,
      fn -> payload.platform.reboot(payload.platform_options) end,
      fn ref, outcome ->
        {:reboot_completed, {ref, outcome}}
      end
    )
  end

  defp maybe_start_effect(_payload), do: :ok

  defp start_effect(payload, ref, work, event_builder) do
    case Effect.start(self(), ref, work, event_builder, timeout: payload.effect_timeout) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Firmware effect launch failed: #{inspect(reason)}"
    end
  end

  defp verification_work(payload, release, path) do
    case payload.artifact.verify(
           path,
           release,
           payload.platform_report.current,
           payload.artifact_options
         ) do
      {:ok, metadata} ->
        journal = journal(payload, :ready)

        case Persistence.save(payload.root, journal) do
          :ok -> {:ok, metadata, journal}
          {:error, reason} -> {:error, {:journal_write_failed, reason}}
        end

      {:error, reason} ->
        payload.artifact.remove(release, payload.root)
        {:error, reason}
    end
  end

  defp preflight_work(payload, release) do
    with {:ok, report} <- synchronized_platform_report(payload),
         true <- report.active_slot == report.next_slot,
         true <- report.current.uuid == payload.platform_report.current.uuid,
         {:ok, checks} <- payload.preflight_provider.(release, report) do
      {:ok, report, checks}
    else
      false -> {:error, :current_firmware_changed}
      {:error, checks} -> {:error, checks}
    end
  end

  defp synchronized_platform_report(payload) do
    with {:ok, report} <- payload.platform.status(payload.platform_options) do
      synchronize_platform_report(payload, report)
    end
  end

  defp synchronize_platform_report(_payload, %{active_slot: slot, next_slot: slot} = report),
    do: {:ok, report}

  defp synchronize_platform_report(payload, _report) do
    with :ok <- payload.platform.synchronize(payload.platform_options),
         {:ok, synchronized} <- payload.platform.status(payload.platform_options),
         true <- synchronized.active_slot == synchronized.next_slot do
      {:ok, synchronized}
    else
      false -> {:error, :firmware_slots_not_synchronized}
      {:error, _reason} = error -> error
    end
  end

  defp installation_work(payload) do
    installing = journal(payload, :installing)

    with :ok <- Persistence.save(payload.root, installing),
         :ok <-
           payload.platform.install_verified(
             payload.artifact_path,
             payload.selected,
             payload.platform_options
           ),
         rebooting = %{installing | phase: :rebooting},
         :ok <- Persistence.save(payload.root, rebooting) do
      {:ok, rebooting}
    else
      {:error, reason} ->
        Persistence.save(payload.root, %{installing | phase: :ready})
        {:error, reason}
    end
  end

  defp validation_work(payload) do
    with :ok <- payload.platform.validate(payload.platform_options),
         {:ok, %{validation: :validated} = report} <-
           payload.platform.status(payload.platform_options),
         :ok <- Persistence.clear(payload.root) do
      if payload.selected, do: payload.artifact.remove(payload.selected, payload.root)
      {:ok, report}
    else
      {:ok, _report} -> {:error, :validation_not_committed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_work(payload, :synchronize) do
    with :ok <- maybe_synchronize_slots(payload),
         {:ok, report} <- payload.platform.status(payload.platform_options),
         :ok <- Persistence.clear(payload.root) do
      if payload.selected, do: payload.artifact.remove(payload.selected, payload.root)
      {:ok, report}
    end
  end

  defp rollback_work(payload, _kind) do
    rolling_back = journal(payload, :rolling_back)

    with :ok <- maybe_save_journal(payload.root, rolling_back),
         :ok <- payload.platform.revert(payload.platform_options) do
      {:ok, rolling_back}
    end
  end

  defp maybe_save_journal(_root, nil), do: :ok
  defp maybe_save_journal(root, journal), do: Persistence.save(root, journal)

  defp maybe_synchronize_slots(%{platform_report: %{active_slot: slot, next_slot: slot}}), do: :ok

  defp maybe_synchronize_slots(payload),
    do: payload.platform.synchronize(payload.platform_options)

  defp complete_check(return_state, outcome, payload) do
    payload = %{payload | next_check_at: monotonic(payload) + payload.check_interval}

    case returned(outcome) do
      {:ok, {:ok, release}} ->
        finish(:checking, :check_completed, return_state, %{
          payload
          | available: release,
            last_error: nil
        })

      {:ok, {:error, reason}} ->
        finish(:checking, :check_completed, return_state, %{
          payload
          | last_error: public_error(reason)
        })

      {:error, reason} ->
        finish(:checking, :check_completed, return_state, %{
          payload
          | last_error: public_error(reason)
        })
    end
  end

  defp acceptance_error(command, payload) do
    connection = command.connection

    cond do
      command.trial_id != trial_id(payload) ->
        :trial_mismatch

      Map.get(connection, :tailnet?) != true ->
        :tailnet_connection_required

      Map.get(connection, :boot_id) != payload.device_boot_id ->
        :fresh_connection_required

      payload.source_connection && Map.get(connection, :id) == payload.source_connection ->
        :fresh_connection_required

      not payload.confirmable ->
        :firmware_not_healthy

      true ->
        nil
    end
  end

  defp update_health(payload, checks, now) do
    healthy = payload.health.healthy?(checks)

    if healthy do
      healthy_since = payload.healthy_since || now

      %{
        payload
        | health_checks: checks,
          healthy_since: healthy_since,
          unhealthy_since: nil,
          ever_healthy: true,
          confirmable: now - healthy_since >= payload.stable_window
      }
    else
      %{
        payload
        | health_checks: checks,
          healthy_since: nil,
          unhealthy_since: payload.unhealthy_since || now,
          confirmable: false
      }
    end
  end

  defp rollback_required?(payload, now) do
    now >= payload.trial_deadline or
      ((payload.ever_healthy and payload.unhealthy_since) &&
         now - payload.unhealthy_since >= payload.health_grace)
  end

  defp begin_rollback(payload, kind) do
    effect_kind = if kind == :synchronize, do: :synchronize, else: :rollback

    %{
      payload
      | effect: %{kind: effect_kind, ref: make_ref()},
        rollback_kind: kind,
        confirmable: false,
        last_error: if(kind == :requested, do: payload.last_error, else: kind)
    }
  end

  defp reset_transaction(payload) do
    %{
      payload
      | selected: nil,
        artifact_path: nil,
        artifact_metadata: nil,
        journal: nil,
        source_connection: nil,
        progress_bytes: 0,
        health_checks: %{},
        healthy_since: nil,
        unhealthy_since: nil,
        ever_healthy: false,
        confirmable: false,
        trial_deadline: nil,
        rollback_kind: nil,
        last_error: nil
    }
  end

  defp journal(%{selected: nil}, _phase), do: nil

  defp journal(payload, phase) do
    %{
      phase: phase,
      release: payload.selected,
      previous_uuid: payload.platform_report.current.uuid,
      source_connection: payload.source_connection,
      source_boot_id: payload.system_boot_id
    }
  end

  defp initial_state(%{supported: false}, _journal, _root, _boot_id, _now, _options),
    do: {:unsupported, nil, nil, nil, nil}

  defp initial_state(report, journal, root, boot_id, _now, _options) do
    if report.validation == :unvalidated do
      selected = journal && journal.release
      {:trial, nil, journal, selected, selected && Artifact.verified_path(root, selected)}
    else
      initial_validated_state(report, journal, root, boot_id)
    end
  end

  defp initial_validated_state(_report, nil, _root, _boot_id), do: checking_state()

  defp initial_validated_state(report, journal, root, boot_id) do
    case journal.phase do
      :ready -> recovered_ready_state(journal, root)
      :installing -> recover_interrupted_install(journal, root)
      :rebooting -> recover_rebooting_state(report, journal, root, boot_id)
      phase when phase in [:trial, :rolling_back] -> synchronization_state(journal, root)
      _unknown -> checking_state()
    end
  end

  defp recovered_ready_state(journal, root) do
    path = Artifact.verified_path(root, journal.release)

    if File.regular?(path),
      do: {:ready, nil, journal, journal.release, path},
      else: checking_state()
  end

  defp recover_interrupted_install(journal, root) do
    path = Artifact.verified_path(root, journal.release)
    recovered = %{journal | phase: :ready}
    Persistence.save(root, recovered)
    {:ready, nil, recovered, recovered.release, path}
  end

  defp recover_rebooting_state(report, journal, root, boot_id) do
    cond do
      journal.release.uuid == report.current.uuid ->
        {:trial, nil, journal, journal.release, Artifact.verified_path(root, journal.release)}

      journal.source_boot_id == boot_id ->
        {:rebooting, %{kind: :reboot, ref: make_ref()}, journal, journal.release,
         Artifact.verified_path(root, journal.release)}

      true ->
        synchronization_state(journal, root)
    end
  end

  defp synchronization_state(journal, root) do
    {:rolling_back, %{kind: :synchronize, ref: make_ref()}, journal, journal.release,
     Artifact.verified_path(root, journal.release)}
  end

  defp checking_state,
    do: {:checking, %{kind: :discovery, ref: make_ref(), return_state: :idle}, nil, nil, nil}

  defp normalize_journal(nil, _report, _root), do: nil

  defp normalize_journal(journal, %{validation: :validated, current: %{uuid: uuid}}, root)
       when journal.phase in [:trial, :rolling_back] and journal.release.uuid == uuid do
    Persistence.clear(root)
    Artifact.remove(journal.release, root)
    nil
  end

  defp normalize_journal(journal, _report, _root), do: journal

  defp trial_deadline(:trial, now, options) do
    timeout = Keyword.get(options, :trial_timeout, @default_trial_timeout)
    uptime = Keyword.get(options, :uptime, &Clock.uptime_ms/0).()
    now + max(timeout - uptime, 0)
  end

  defp trial_deadline(_state, _now, _options), do: nil

  defp public_status(state, payload) do
    report = payload.platform_report
    selected = payload.selected

    %Status{
      supported: report.supported,
      phase: state,
      current: report.current,
      validation: public_validation(report.validation),
      available: payload.available && Release.public(payload.available),
      artifact: public_artifact(state, payload),
      progress: progress(payload),
      health: payload.health_checks,
      trial: public_trial(state, payload, selected),
      last_checked_at: payload.last_checked_at,
      last_error: payload.last_error
    }
  end

  defp public_artifact(state, payload)
       when state in [:downloading, :verifying, :ready, :preflight, :installing] do
    if payload.selected do
      %{
        id: payload.selected.id,
        version: payload.selected.version,
        size: payload.selected.size,
        downloaded: min(payload.progress_bytes, payload.selected.size),
        verified: state in [:ready, :preflight, :installing]
      }
    end
  end

  defp public_artifact(_state, _payload), do: nil

  defp public_trial(state, payload, selected)
       when state in [:trial, :validating, :rolling_back] do
    %{
      id: trial_id(payload),
      version: (selected && selected.version) || payload.platform_report.current.version,
      confirmable: payload.confirmable,
      remaining_seconds: remaining_seconds(payload)
    }
  end

  defp public_trial(_state, _payload, _selected), do: nil

  defp progress(%{selected: nil}), do: nil

  defp progress(%{selected: %{size: size}, progress_bytes: bytes}) when size > 0,
    do: min(div(bytes * 100, size), 100)

  defp remaining_seconds(%{trial_deadline: nil}), do: 0

  defp remaining_seconds(payload),
    do: max(div(payload.trial_deadline - monotonic(payload), 1_000), 0)

  defp unsupported_status do
    %Status{
      supported: false,
      phase: :unsupported,
      current: %{},
      validation: :unsupported
    }
  end

  defp public_validation(:validated), do: :validated
  defp public_validation(:unvalidated), do: :trial
  defp public_validation(:unknown), do: :unknown

  defp fail(from, event, payload, reason),
    do: finish(from, event, :failed, %{payload | last_error: public_error(reason)})

  defp returned({:returned, result}), do: {:ok, result}
  defp returned(:timed_out), do: {:error, :operation_timeout}
  defp returned(:cancelled), do: {:error, :operation_cancelled}
  defp returned({:crashed, _kind, _reason, _stacktrace}), do: {:error, :operation_crashed}

  defp result(payload, relay, value), do: %{payload | reply: {relay, value}}

  defp finish(from, event, to, payload) do
    {:ok, to, Diagnostics.record(payload, from, event, to)}
  end

  defp request(server, event, payload), do: Diagnostics.request(server, event, payload, 10_000)
  defp check_return(:failed), do: :idle
  defp check_return(state), do: state
  defp trial_id(payload), do: payload.platform_report.current.uuid
  defp rollback_kind(%{kind: :synchronize}), do: :synchronize
  defp rollback_kind(_effect), do: nil

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error({reason, _detail}) when is_atom(reason), do: reason
  defp public_error({reason, _detail, _extra}) when is_atom(reason), do: reason
  defp public_error(_reason), do: :firmware_operation_failed

  defp platform_report(platform, options) do
    case platform.status(options) do
      {:ok, report} -> {report, nil}
      {:error, _reason} -> {fallback_report(), :platform_status_failed}
    end
  end

  defp fallback_report do
    {:ok, report} = NervesGate.Firmware.Platform.Host.status([])
    report
  end

  defp journal(root) do
    case Persistence.load(root) do
      {:ok, journal} -> {journal, nil}
      {:error, _reason} -> {nil, :firmware_journal_invalid}
    end
  end

  defp artifact_size(nil), do: 0

  defp artifact_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  defp monotonic(%{monotonic: function}), do: function.()
  defp monotonic(options), do: Keyword.get(options, :monotonic, &Clock.monotonic_ms/0).()

  defp device_boot_id do
    NervesGate.DeviceState.snapshot().boot_id
  catch
    :exit, _reason -> "starting"
  end

  defp publish(status) do
    case NervesGate.DeviceState.publish({:state_reported, :firmware, status}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Firmware DeviceState publication failed: #{inspect(reason)}"
    end
  end
end
