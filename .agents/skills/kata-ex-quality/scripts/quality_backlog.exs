defmodule KataExQuality.CSV do
  @moduledoc false

  def read!(path, expected_header) do
    lines =
      path
      |> File.read!()
      |> String.split(~r/\r?\n/, trim: false)
      |> drop_final_empty()

    case lines do
      [] ->
        raise "#{path}: empty CSV"

      [header | rows] ->
        parsed_header = parse_line!(header, path, 1)

        if parsed_header != expected_header do
          raise "#{path}: unexpected header\nexpected: #{Enum.join(expected_header, ",")}\nactual:   #{header}"
        end

        rows
        |> Enum.with_index(2)
        |> Enum.map(fn
          {"", line} ->
            raise "#{path}:#{line}: blank records are not allowed"

          {row, line} ->
            values = parse_line!(row, path, line)

            if length(values) != length(expected_header) do
              raise "#{path}:#{line}: expected #{length(expected_header)} fields, got #{length(values)}"
            end

            Map.new(Enum.zip(expected_header, values))
        end)
    end
  end

  def write!(path, header, rows) do
    contents =
      [
        encode_row(header)
        | Enum.map(rows, &encode_row(Enum.map(header, fn key -> Map.fetch!(&1, key) end)))
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, contents)
      File.rename!(temporary, path)
    after
      if File.exists?(temporary), do: File.rm!(temporary)
    end
  end

  def encode_row(values), do: Enum.map_join(values, ",", &encode_field/1)

  defp encode_field(value) do
    value = to_string(value)

    if String.contains?(value, ["\n", "\r"]) do
      raise "CSV fields cannot contain line breaks"
    end

    if String.contains?(value, [",", "\""]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp parse_line!(line, path, number) do
    case parse(line, [], "", :plain) do
      {:ok, values} -> values
      {:error, reason} -> raise "#{path}:#{number}: #{reason}"
    end
  end

  defp parse(<<>>, fields, field, :plain), do: {:ok, Enum.reverse([field | fields])}
  defp parse(<<>>, fields, field, :closed), do: {:ok, Enum.reverse([field | fields])}
  defp parse(<<>>, _fields, _field, :quoted), do: {:error, "unclosed quoted field"}

  defp parse(<<",", rest::binary>>, fields, field, :plain),
    do: parse(rest, [field | fields], "", :plain)

  defp parse(<<"\"", rest::binary>>, fields, "", :plain),
    do: parse(rest, fields, "", :quoted)

  defp parse(<<"\"", _rest::binary>>, _fields, _field, :plain),
    do: {:error, "quote inside an unquoted field"}

  defp parse(<<"\"\"", rest::binary>>, fields, field, :quoted),
    do: parse(rest, fields, field <> "\"", :quoted)

  defp parse(<<"\"", rest::binary>>, fields, field, :quoted),
    do: parse(rest, fields, field, :closed)

  defp parse(<<",", rest::binary>>, fields, field, :closed),
    do: parse(rest, [field | fields], "", :plain)

  defp parse(<<_char::utf8, _rest::binary>>, _fields, _field, :closed),
    do: {:error, "characters after a closed quoted field"}

  defp parse(<<char::utf8, rest::binary>>, fields, field, state),
    do: parse(rest, fields, field <> <<char::utf8>>, state)

  defp drop_final_empty(lines) do
    case Enum.reverse(lines) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> lines
    end
  end
end

defmodule KataExQuality.Backlog do
  @moduledoc false

  alias KataExQuality.CSV

  @backlog_header ~w(schema_version id rule_id rule_version status class priority confidence scope location summary owner depends_on batch_id latest_evidence_id first_seen last_seen closed_on)
  @evidence_header ~w(schema_version evidence_id finding_id source_revision observed_on command measure before_value after_value unit result artifact notes)
  @rules_header ~w(schema_version rule_id rule_version status surface cost requires default_class auto_fix playbook owner reason)

  @statuses ~w(open selected in_progress fixed verified deferred invalid blocked)
  @classes ~w(objective-fix safe-refinement backpressure-gap judgment-required)
  @priorities ~w(p0 p1 p2 p3)
  @confidences ~w(confirmed supported candidate)
  @evidence_results ~w(fail pass blocked not_run)
  @rule_statuses ~w(enabled disabled not_applicable)
  @surfaces ~w(gates proof tests code architecture)
  @costs ~w(cheap normal expensive)
  @auto_fix ~w(yes no)
  @auto_classes ~w(objective-fix safe-refinement)

  @built_in_rules %{
    "gate-failure-router" => "1",
    "format-drift" => "1",
    "compile-warning" => "1",
    "credo-finding" => "2",
    "dialyzer-warning" => "1",
    "documentation-gap" => "1",
    "quality-contract-drift" => "1",
    "stale-waiver-or-ignore" => "1",
    "unused-dependency" => "1",
    "package-artifact-drift" => "1",
    "coverage-gap" => "2",
    "contract-or-mutation-gap" => "1",
    "required-suite-instability" => "1",
    "stale-proof-evidence" => "1",
    "component-ownership-gap" => "1",
    "component-proof-gap" => "1",
    "changed-line-coverage-regression" => "1",
    "property-invariant-gap" => "1",
    "fuzz-replay-gap" => "1",
    "performance-proof-gap" => "1",
    "public-example-proof-gap" => "1",
    "waiver-governance-gap" => "1",
    "test-value-gap" => "1",
    "test-arbitrary-sleep" => "2",
    "test-unnecessary-serialization" => "2",
    "test-fixture-duplication" => "2",
    "test-runtime-hotspot" => "2",
    "test-order-dependence" => "1",
    "test-process-leak" => "1",
    "test-shared-state-leak" => "1",
    "test-external-nondeterminism" => "1",
    "test-broad-setup" => "1",
    "test-hidden-expected-value" => "1",
    "test-implementation-coupling" => "1",
    "test-boundary-proof-gap" => "1",
    "test-randomness-replay-gap" => "1",
    "test-assertion-gap" => "1",
    "duplicate-code" => "2",
    "confirmed-dead-code" => "2",
    "data-access-shape-mismatch" => "1",
    "data-invariant-gap" => "1",
    "normalization-owner-gap" => "1",
    "boundary-key-shape-drift" => "1",
    "data-roundtrip-loss" => "1",
    "error-contract-drift" => "1",
    "internal-wire-data-conflation" => "1",
    "invalid-state-encoding" => "1",
    "option-flag-complexity" => "1",
    "wrapper-without-contract" => "1",
    "unsafe-compile-time-data" => "1",
    "observable-secret-leak" => "1",
    "broad-exception-recovery" => "1",
    "architecture-policy-violation" => "1",
    "backpressure-capability-gap" => "1",
    "data-before-process-gap" => "1",
    "functional-core-gap" => "1",
    "process-without-runtime-need" => "1",
    "process-machinery-leak" => "1",
    "boundary-api-gap" => "1",
    "call-cast-backpressure-gap" => "1",
    "lifecycle-owner-gap" => "1",
    "state-transition-multi-owner" => "1",
    "unsupervised-process" => "1",
    "task-owner-gap" => "1",
    "timer-monitor-cleanup-gap" => "1",
    "blocking-server-callback" => "1",
    "mailbox-pressure-gap" => "1",
    "oversized-process-message" => "1",
    "derivable-process-state" => "1",
    "persistence-core-coupling" => "1",
    "external-effect-idempotency-gap" => "1",
    "fault-domain-mismatch" => "1",
    "retry-policy-gap" => "1",
    "shutdown-cleanup-gap" => "1",
    "supervision-policy-mismatch" => "1",
    "layer-dependency-inversion" => "1"
  }

  @non_auto_built_in_rules ~w(
    gate-failure-router
    quality-contract-drift
    stale-proof-evidence
    component-ownership-gap
    performance-proof-gap
    waiver-governance-gap
    test-value-gap
    data-access-shape-mismatch
    internal-wire-data-conflation
    invalid-state-encoding
    option-flag-complexity
    wrapper-without-contract
    backpressure-capability-gap
    data-before-process-gap
    functional-core-gap
    process-without-runtime-need
    call-cast-backpressure-gap
    blocking-server-callback
    mailbox-pressure-gap
    oversized-process-message
    derivable-process-state
    persistence-core-coupling
    external-effect-idempotency-gap
    fault-domain-mismatch
    layer-dependency-inversion
  )

  @built_in_rule_history %{
    "credo-finding" => ~w(1 2),
    "coverage-gap" => ~w(1 2),
    "test-arbitrary-sleep" => ~w(1 2),
    "test-unnecessary-serialization" => ~w(1 2),
    "test-fixture-duplication" => ~w(1 2),
    "test-runtime-hotspot" => ~w(1 2),
    "duplicate-code" => ~w(1 2),
    "confirmed-dead-code" => ~w(1 2)
  }

  @transitions %{
    "open" => ~w(selected verified deferred invalid blocked),
    "selected" => ~w(in_progress open blocked),
    "in_progress" => ~w(fixed verified open blocked),
    "fixed" => ~w(in_progress verified open blocked),
    "verified" => ~w(open),
    "deferred" => ~w(open invalid blocked),
    "invalid" => ~w(open),
    "blocked" => ~w(open deferred invalid)
  }

  @switches [
    root: :string,
    backlog: :string,
    evidence: :string,
    rules: :string,
    status: :string,
    ids: :string,
    limit: :integer,
    batch: :string,
    date: :string,
    rule_id: :string,
    rule_version: :integer,
    class: :string,
    priority: :string,
    confidence: :string,
    scope: :string,
    location: :string,
    summary: :string,
    owner: :string,
    depends_on: :string,
    finding_id: :string,
    source_revision: :string,
    command: :string,
    measure: :string,
    before: :string,
    after: :string,
    unit: :string,
    result: :string,
    artifact: :string,
    notes: :string,
    evidence_id: :string,
    surface: :string,
    cost: :string,
    requires: :string,
    auto_fix: :string,
    playbook: :string,
    reason: :string
  ]

  def main(argv) do
    case argv do
      [] -> help()
      ["help" | _] -> help()
      [command | args] -> run(command, args)
    end
  rescue
    error ->
      IO.puts(:stderr, "quality backlog error: #{Exception.message(error)}")
      System.halt(1)
  end

  defp run(command, args) do
    {opts, positional} = parse_options!(args)
    if positional != [], do: raise("unexpected arguments: #{Enum.join(positional, " ")}")
    paths = paths(opts)

    case command do
      "init" -> init(paths)
      "check" -> check(paths)
      "list" -> list(paths, opts)
      "add" -> add(paths, opts)
      "evidence" -> evidence(paths, opts)
      "rule" -> rule(paths, opts)
      "select" -> select(paths, opts)
      "update-status" -> update_status(paths, opts)
      _ -> raise "unknown command #{inspect(command)}; run help"
    end
  end

  defp help do
    IO.puts("""
    Elixir quality backlog tool

      init [path options]
      check [path options]
      list [--status STATUS] [path options]
      add --rule-id ID --rule-version N --class CLASS --priority P0..P3
          --confidence CONFIDENCE --scope SCOPE --location LOCATION
          --summary TEXT --owner OWNER --source-revision REV --command COMMAND
          --measure MEASURE --before VALUE --unit UNIT --result RESULT
          [--after VALUE] [--artifact PATH] [--notes TEXT] [--depends-on IDS]
      evidence --finding-id EXQ-NNNN --source-revision REV --command COMMAND
          --measure MEASURE --before VALUE --unit UNIT --result RESULT
          [--after VALUE] [--artifact PATH] [--notes TEXT]
      rule --rule-id ID --rule-version N --status STATUS --owner OWNER
          [--surface SURFACE] [--cost COST] [--requires CAPABILITY]
          [--class CLASS] [--auto-fix yes|no] [--playbook PATH] [--reason TEXT]
      select --ids ID;ID --batch EXQ-B-YYYYMMDD-NN --limit N
      update-status --ids ID;ID --status STATUS [--evidence-id EXQ-E-NNNN]

    Path options: --root PATH --backlog PATH --evidence PATH --rules PATH
    Date option: --date YYYY-MM-DD
    """)
  end

  defp parse_options!(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")
    {opts, positional}
  end

  defp paths(opts) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    %{
      root: root,
      backlog: safe_path!(root, Keyword.get(opts, :backlog, "docs/quality/backlog.csv")),
      evidence: safe_path!(root, Keyword.get(opts, :evidence, "docs/quality/evidence.csv")),
      rules: safe_path!(root, Keyword.get(opts, :rules, "docs/quality/rules.csv"))
    }
  end

  defp safe_path!(root, path) do
    expanded = Path.expand(path, root)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      expanded
    else
      raise "managed path leaves project root: #{path}"
    end
  end

  defp init(paths) do
    create_if_missing(paths.backlog, @backlog_header)
    create_if_missing(paths.evidence, @evidence_header)
    create_if_missing(paths.rules, @rules_header)
    check(paths)
  end

  defp create_if_missing(path, header) do
    unless File.exists?(path), do: CSV.write!(path, header, [])
  end

  defp check(paths) do
    {backlog, evidence, rules} = load!(paths)

    IO.puts(
      "quality backlog check passed: #{length(backlog)} findings, #{length(evidence)} evidence records, #{length(rules)} project rules"
    )
  end

  defp load!(paths) do
    backlog = CSV.read!(paths.backlog, @backlog_header)
    evidence = CSV.read!(paths.evidence, @evidence_header)
    rules = CSV.read!(paths.rules, @rules_header)

    validate_backlog!(backlog)
    validate_evidence!(evidence, backlog, paths.root)
    validate_rules!(rules, paths.root)
    validate_finding_rules!(backlog, rules)
    validate_links!(backlog, evidence)
    {backlog, evidence, rules}
  end

  defp list(paths, opts) do
    {backlog, _evidence, _rules} = load!(paths)
    status = Keyword.get(opts, :status)
    if status, do: member!(status, @statuses, "status")
    rows = if status, do: Enum.filter(backlog, &(&1["status"] == status)), else: backlog
    IO.puts(CSV.encode_row(@backlog_header))
    Enum.each(rows, fn row -> IO.puts(CSV.encode_row(Enum.map(@backlog_header, &row[&1]))) end)
  end

  defp add(paths, opts) do
    {backlog, evidence, rules} = load!(paths)
    date = date!(opts)
    id = next_id(backlog, "id", "EXQ-")
    evidence_id = next_id(evidence, "evidence_id", "EXQ-E-")

    row = %{
      "schema_version" => "1",
      "id" => id,
      "rule_id" => required!(opts, :rule_id),
      "rule_version" => required_integer!(opts, :rule_version),
      "status" => "open",
      "class" => required!(opts, :class),
      "priority" => required!(opts, :priority),
      "confidence" => required!(opts, :confidence),
      "scope" => required!(opts, :scope),
      "location" => required!(opts, :location),
      "summary" => required!(opts, :summary),
      "owner" => required!(opts, :owner),
      "depends_on" => Keyword.get(opts, :depends_on, ""),
      "batch_id" => "",
      "latest_evidence_id" => evidence_id,
      "first_seen" => date,
      "last_seen" => date,
      "closed_on" => ""
    }

    evidence_row = evidence_row(opts, evidence_id, id, date)

    if row["confidence"] == "confirmed" and evidence_row["result"] != "fail" do
      raise "confirmed new findings require failing evidence"
    end

    ensure_new_finding!(backlog, row)
    ensure_current_rule_version!(row)

    new_backlog = backlog ++ [row]
    new_evidence = evidence ++ [evidence_row]
    validate_backlog!(new_backlog)
    validate_evidence!(new_evidence, new_backlog, paths.root)
    validate_rules!(rules, paths.root)
    rule_applicable!(row, rules)
    validate_links!(new_backlog, new_evidence)
    CSV.write!(paths.evidence, @evidence_header, new_evidence)
    CSV.write!(paths.backlog, @backlog_header, new_backlog)
    IO.puts("added #{id} with evidence #{evidence_id}")
  end

  defp evidence(paths, opts) do
    {backlog, evidence, rules} = load!(paths)
    finding_id = required!(opts, :finding_id)
    ensure_finding!(backlog, finding_id)
    date = date!(opts)
    evidence_id = next_id(evidence, "evidence_id", "EXQ-E-")
    row = evidence_row(opts, evidence_id, finding_id, date)
    new_evidence = evidence ++ [row]

    new_backlog =
      Enum.map(backlog, fn finding ->
        if finding["id"] == finding_id do
          %{finding | "latest_evidence_id" => evidence_id, "last_seen" => date}
        else
          finding
        end
      end)

    validate_backlog!(new_backlog)
    validate_evidence!(new_evidence, new_backlog, paths.root)
    validate_rules!(rules, paths.root)
    validate_links!(new_backlog, new_evidence)
    CSV.write!(paths.evidence, @evidence_header, new_evidence)
    CSV.write!(paths.backlog, @backlog_header, new_backlog)
    IO.puts("added evidence #{evidence_id} for #{finding_id}")
  end

  defp evidence_row(opts, evidence_id, finding_id, date) do
    %{
      "schema_version" => "1",
      "evidence_id" => evidence_id,
      "finding_id" => finding_id,
      "source_revision" => required!(opts, :source_revision),
      "observed_on" => date,
      "command" => required!(opts, :command),
      "measure" => required!(opts, :measure),
      "before_value" => required!(opts, :before),
      "after_value" => Keyword.get(opts, :after, ""),
      "unit" => required!(opts, :unit),
      "result" => required!(opts, :result),
      "artifact" => Keyword.get(opts, :artifact, ""),
      "notes" => Keyword.get(opts, :notes, "")
    }
  end

  defp rule(paths, opts) do
    {backlog, evidence, rules} = load!(paths)
    rule_id = required!(opts, :rule_id)

    row = %{
      "schema_version" => "1",
      "rule_id" => rule_id,
      "rule_version" => required_integer!(opts, :rule_version),
      "status" => required!(opts, :status),
      "surface" => Keyword.get(opts, :surface, ""),
      "cost" => Keyword.get(opts, :cost, ""),
      "requires" => Keyword.get(opts, :requires, ""),
      "default_class" => Keyword.get(opts, :class, ""),
      "auto_fix" => Keyword.get(opts, :auto_fix, ""),
      "playbook" => Keyword.get(opts, :playbook, ""),
      "owner" => required!(opts, :owner),
      "reason" => Keyword.get(opts, :reason, "")
    }

    new_rules =
      if Enum.any?(rules, &(&1["rule_id"] == rule_id)) do
        Enum.map(rules, fn existing ->
          if existing["rule_id"] == rule_id, do: row, else: existing
        end)
      else
        rules ++ [row]
      end

    validate_rules!(new_rules, paths.root)
    validate_finding_rules!(backlog, new_rules)
    validate_links!(backlog, evidence)
    CSV.write!(paths.rules, @rules_header, new_rules)
    IO.puts("recorded project rule #{rule_id} as #{row["status"]}")
  end

  defp select(paths, opts) do
    {backlog, evidence, rules} = load!(paths)
    ids = ids!(opts)
    limit = Keyword.get(opts, :limit) || raise "select requires --limit"
    batch = required!(opts, :batch)
    if limit < 1, do: raise("limit must be positive")
    if length(ids) > limit, do: raise("selection has #{length(ids)} rows but limit is #{limit}")
    batch!(batch)
    ensure_unique_requested!(ids)

    if Enum.any?(backlog, &(&1["batch_id"] == batch)) do
      raise "batch ID #{batch} has already been used"
    end

    by_id = Map.new(backlog, &{&1["id"], &1})

    Enum.each(ids, fn id ->
      row = Map.get(by_id, id) || raise "unknown finding #{id}"
      if row["status"] != "open", do: raise("#{id}: expected open status")

      if row["confidence"] != "confirmed",
        do: raise("#{id}: selection requires confirmed confidence")

      if row["class"] not in @auto_classes,
        do: raise("#{id}: class is not eligible for automatic application")

      ensure_current_rule_version!(row)
      rule_applicable!(row, rules)
      rule_auto_fixable!(row, rules)
      latest = Enum.find(evidence, &(&1["evidence_id"] == row["latest_evidence_id"]))

      if is_nil(latest) or latest["result"] != "fail" do
        raise "#{id}: selection requires current failing evidence"
      end

      dependencies(row)
      |> Enum.each(fn dependency ->
        dependency_row =
          Map.get(by_id, dependency) || raise "#{id}: unknown dependency #{dependency}"

        if dependency_row["status"] != "verified",
          do: raise("#{id}: dependency #{dependency} is not verified")
      end)
    end)

    new_backlog =
      Enum.map(backlog, fn row ->
        if row["id"] in ids, do: %{row | "status" => "selected", "batch_id" => batch}, else: row
      end)

    validate_backlog!(new_backlog)
    validate_links!(new_backlog, evidence)
    CSV.write!(paths.backlog, @backlog_header, new_backlog)
    IO.puts("selected #{Enum.join(ids, ", ")} as #{batch}")
    validate_rules!(rules, paths.root)
  end

  defp update_status(paths, opts) do
    {backlog, evidence, rules} = load!(paths)
    ids = ids!(opts)
    target = required!(opts, :status)
    date = date!(opts)
    member!(target, @statuses, "status")
    ensure_unique_requested!(ids)
    by_id = Map.new(backlog, &{&1["id"], &1})
    rows = Enum.map(ids, &(Map.get(by_id, &1) || raise("unknown finding #{&1}")))

    Enum.each(rows, fn row ->
      allowed = Map.fetch!(@transitions, row["status"])

      if target not in allowed,
        do: raise("#{row["id"]}: invalid transition #{row["status"]} -> #{target}")
    end)

    enforce_atomic_batch!(backlog, rows, target)
    selected_evidence = Keyword.get(opts, :evidence_id)

    new_backlog =
      Enum.map(backlog, fn row ->
        if row["id"] in ids do
          latest = selected_evidence || row["latest_evidence_id"]
          verify_evidence_for_status!(row["id"], target, latest, evidence)

          row
          |> Map.put("status", target)
          |> Map.put("latest_evidence_id", latest)
          |> Map.put("last_seen", date)
          |> Map.put("closed_on", if(target in ~w(verified invalid), do: date, else: ""))
          |> maybe_clear_batch(target)
        else
          row
        end
      end)

    validate_backlog!(new_backlog)
    validate_evidence!(evidence, new_backlog, paths.root)
    validate_rules!(rules, paths.root)
    validate_links!(new_backlog, evidence)
    CSV.write!(paths.backlog, @backlog_header, new_backlog)
    IO.puts("updated #{Enum.join(ids, ", ")} to #{target}")
  end

  defp maybe_clear_batch(row, "open"), do: Map.put(row, "batch_id", "")
  defp maybe_clear_batch(row, _target), do: row

  defp enforce_atomic_batch!(backlog, rows, target) do
    batches = rows |> Enum.map(& &1["batch_id"]) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    active? = Enum.any?(rows, &(&1["status"] in ~w(selected in_progress fixed blocked)))

    if active? do
      if length(batches) > 1, do: raise("one status update cannot span batches")

      case batches do
        [batch] ->
          active_ids =
            backlog
            |> Enum.filter(
              &(&1["batch_id"] == batch and
                  &1["status"] in ~w(selected in_progress fixed blocked))
            )
            |> Enum.map(& &1["id"])
            |> MapSet.new()

          requested = rows |> Enum.map(& &1["id"]) |> MapSet.new()

          if active_ids != requested,
            do: raise("update must include every active row in batch #{batch}")

        [] ->
          raise "#{target} requires a selected batch"
      end
    else
      if target in ~w(in_progress fixed), do: raise("#{target} requires a selected batch")
    end
  end

  defp verify_evidence_for_status!(_id, target, _evidence_id, _evidence)
       when target not in ~w(verified invalid),
       do: :ok

  defp verify_evidence_for_status!(id, target, evidence_id, evidence) do
    if evidence_id in [nil, ""], do: raise("#{id}: #{target} requires evidence")
    row = Enum.find(evidence, &(&1["evidence_id"] == evidence_id and &1["finding_id"] == id))
    if is_nil(row), do: raise("#{id}: evidence #{evidence_id} does not belong to the finding")

    if target == "verified" and row["result"] != "pass",
      do: raise("#{id}: verified requires passing evidence")
  end

  defp validate_backlog!(rows) do
    unique!(rows, "id")

    Enum.each(rows, fn row ->
      value!(row, "schema_version", ["1"])
      regex!(row, "id", ~r/^EXQ-\d{4,}$/)
      nonempty!(row, ~w(rule_id rule_version scope location summary owner first_seen last_seen))
      positive_integer!(row["rule_version"], "#{row["id"]}: rule_version")
      value!(row, "status", @statuses)
      value!(row, "class", @classes)
      value!(row, "priority", @priorities)
      value!(row, "confidence", @confidences)
      date_string!(row["first_seen"], "#{row["id"]}: first_seen")
      date_string!(row["last_seen"], "#{row["id"]}: last_seen")

      if row["batch_id"] != "", do: batch!(row["batch_id"])
      if row["latest_evidence_id"] != "", do: evidence_id!(row["latest_evidence_id"])

      if row["status"] in ~w(selected in_progress fixed) and row["batch_id"] == "" do
        raise "#{row["id"]}: #{row["status"]} requires batch_id"
      end

      if row["status"] in ~w(verified invalid) do
        date_string!(row["closed_on"], "#{row["id"]}: closed_on")
      else
        if row["closed_on"] != "",
          do: raise("#{row["id"]}: closed_on is only valid for verified or invalid")
      end
    end)

    ids = MapSet.new(Enum.map(rows, & &1["id"]))

    Enum.each(rows, fn row ->
      Enum.each(dependencies(row), fn dependency ->
        if dependency == row["id"], do: raise("#{row["id"]}: cannot depend on itself")

        unless MapSet.member?(ids, dependency),
          do: raise("#{row["id"]}: unknown dependency #{dependency}")
      end)
    end)
  end

  defp validate_evidence!(rows, backlog, root) do
    unique!(rows, "evidence_id")
    finding_ids = MapSet.new(Enum.map(backlog, & &1["id"]))

    Enum.each(rows, fn row ->
      value!(row, "schema_version", ["1"])
      evidence_id!(row["evidence_id"])

      nonempty!(
        row,
        ~w(finding_id source_revision observed_on command measure before_value unit result)
      )

      unless MapSet.member?(finding_ids, row["finding_id"]),
        do: raise("#{row["evidence_id"]}: unknown finding #{row["finding_id"]}")

      date_string!(row["observed_on"], "#{row["evidence_id"]}: observed_on")
      value!(row, "result", @evidence_results)

      if row["result"] == "pass" and row["after_value"] == "" do
        raise "#{row["evidence_id"]}: passing evidence requires after_value"
      end

      if row["artifact"] != "" do
        artifact = safe_path!(root, row["artifact"])
        unless File.exists?(artifact), do: raise("#{row["evidence_id"]}: artifact does not exist")
      end
    end)
  end

  defp validate_rules!(rows, root) do
    unique!(rows, "rule_id")

    Enum.each(rows, fn row ->
      value!(row, "schema_version", ["1"])
      nonempty!(row, ~w(rule_id rule_version status owner))
      positive_integer!(row["rule_version"], "#{row["rule_id"]}: rule_version")
      value!(row, "status", @rule_statuses)

      case Map.get(@built_in_rules, row["rule_id"]) do
        nil ->
          nonempty!(row, ~w(surface cost requires default_class auto_fix playbook))
          value!(row, "surface", @surfaces)
          value!(row, "cost", @costs)
          value!(row, "default_class", @classes)
          value!(row, "auto_fix", @auto_fix)
          safe_path!(root, row["playbook"])

          unless File.exists?(safe_path!(root, row["playbook"])),
            do: raise("#{row["rule_id"]}: playbook does not exist")

        version ->
          if row["rule_version"] != version,
            do: raise("#{row["rule_id"]}: built-in version must be #{version}")
      end

      if row["status"] in ~w(disabled not_applicable) and row["reason"] == "" do
        raise "#{row["rule_id"]}: #{row["status"]} requires reason"
      end
    end)
  end

  defp validate_finding_rules!(backlog, rules) do
    Enum.each(backlog, fn row ->
      case Map.get(@built_in_rules, row["rule_id"]) do
        nil ->
          project_rule = Enum.find(rules, &(&1["rule_id"] == row["rule_id"]))

          if is_nil(project_rule) do
            raise "#{row["id"]}: project rule #{row["rule_id"]} is not registered"
          end

          if project_rule["rule_version"] != row["rule_version"] do
            raise "#{row["id"]}: rule version does not match project registry"
          end

        current_version ->
          if row["rule_id"] == "gate-failure-router" do
            raise "#{row["id"]}: gate-failure-router cannot own a finding"
          end

          supported_versions =
            Map.get(@built_in_rule_history, row["rule_id"], [current_version])

          if row["rule_version"] not in supported_versions do
            raise "#{row["id"]}: unsupported built-in rule version #{row["rule_version"]}"
          end
      end
    end)
  end

  defp ensure_current_rule_version!(row) do
    case Map.get(@built_in_rules, row["rule_id"]) do
      nil ->
        :ok

      current_version ->
        if row["rule_version"] != current_version do
          raise "#{row["id"]}: re-evaluate rule #{row["rule_id"]} version #{row["rule_version"]} against current version #{current_version} before selection"
        end
    end
  end

  defp rule_applicable!(row, rules) do
    applicability = Enum.find(rules, &(&1["rule_id"] == row["rule_id"]))

    if applicability && applicability["status"] in ~w(disabled not_applicable) do
      raise "#{row["id"]}: rule #{row["rule_id"]} is #{applicability["status"]}"
    end

    if Map.has_key?(@built_in_rules, row["rule_id"]) do
      :ok
    else
      if is_nil(applicability) or applicability["status"] != "enabled" do
        raise "#{row["id"]}: project rule #{row["rule_id"]} is not enabled"
      end
    end
  end

  defp rule_auto_fixable!(row, rules) do
    case Map.get(@built_in_rules, row["rule_id"]) do
      nil ->
        rule = Enum.find(rules, &(&1["rule_id"] == row["rule_id"]))

        if is_nil(rule) or rule["auto_fix"] != "yes",
          do: raise("#{row["id"]}: project rule is not auto-fixable")

      _version ->
        if row["rule_id"] in @non_auto_built_in_rules do
          raise "#{row["id"]}: built-in rule is not auto-fixable"
        end
    end
  end

  defp validate_links!(backlog, evidence) do
    by_evidence = Map.new(evidence, &{&1["evidence_id"], &1})

    Enum.each(backlog, fn row ->
      case row["latest_evidence_id"] do
        "" ->
          if row["confidence"] == "confirmed",
            do: raise("#{row["id"]}: confirmed finding requires evidence")

        evidence_id ->
          linked =
            Map.get(by_evidence, evidence_id) ||
              raise "#{row["id"]}: unknown evidence #{evidence_id}"

          if linked["finding_id"] != row["id"],
            do: raise("#{row["id"]}: latest evidence belongs to #{linked["finding_id"]}")

          if row["status"] == "verified" and linked["result"] != "pass",
            do: raise("#{row["id"]}: verified finding requires passing evidence")
      end
    end)
  end

  defp next_id(rows, field, prefix) do
    number =
      rows
      |> Enum.map(fn row ->
        row[field]
        |> String.replace_prefix(prefix, "")
        |> String.to_integer()
      end)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    prefix <> String.pad_leading(Integer.to_string(number), 4, "0")
  end

  defp ids!(opts) do
    opts
    |> required!(:ids)
    |> String.split(";", trim: true)
    |> tap(fn ids -> if ids == [], do: raise("--ids must contain at least one ID") end)
  end

  defp ensure_unique_requested!(ids) do
    if length(ids) != length(Enum.uniq(ids)), do: raise("requested IDs contain duplicates")
  end

  defp ensure_new_finding!(backlog, candidate) do
    duplicate =
      Enum.find(backlog, fn row ->
        row["status"] != "invalid" and
          row["rule_id"] == candidate["rule_id"] and
          row["rule_version"] == candidate["rule_version"] and
          row["scope"] == candidate["scope"] and
          row["location"] == candidate["location"] and
          normalize(row["summary"]) == normalize(candidate["summary"])
      end)

    if duplicate, do: raise("finding duplicates #{duplicate["id"]}")
  end

  defp normalize(value),
    do: value |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp ensure_finding!(backlog, id) do
    unless Enum.any?(backlog, &(&1["id"] == id)), do: raise("unknown finding #{id}")
  end

  defp dependencies(row), do: String.split(row["depends_on"], ";", trim: true)

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> raise "missing --#{key |> Atom.to_string() |> String.replace("_", "-")}"
      "" -> raise "empty --#{key |> Atom.to_string() |> String.replace("_", "-")}"
      value -> to_string(value)
    end
  end

  defp required_integer!(opts, key) do
    value =
      Keyword.get(opts, key) ||
        raise "missing --#{key |> Atom.to_string() |> String.replace("_", "-")}"

    if value < 1, do: raise("--#{key} must be positive")
    Integer.to_string(value)
  end

  defp date!(opts) do
    value = Keyword.get(opts, :date, Date.utc_today() |> Date.to_iso8601())
    date_string!(value, "date")
    value
  end

  defp unique!(rows, field) do
    duplicates =
      rows
      |> Enum.frequencies_by(& &1[field])
      |> Enum.filter(fn {value, count} -> value != "" and count > 1 end)

    if duplicates != [],
      do: raise("duplicate #{field}: #{inspect(Enum.map(duplicates, &elem(&1, 0)))}")
  end

  defp nonempty!(row, fields) do
    Enum.each(fields, fn field ->
      if row[field] in [nil, ""],
        do: raise("#{row["id"] || row["rule_id"] || "row"}: #{field} is required")
    end)
  end

  defp value!(row, field, allowed),
    do: member!(row[field], allowed, "#{row["id"] || row["rule_id"] || "row"}: #{field}")

  defp member!(value, allowed, label) do
    unless value in allowed,
      do: raise("#{label} must be one of #{Enum.join(allowed, ", ")}; got #{inspect(value)}")
  end

  defp regex!(row, field, regex) do
    unless Regex.match?(regex, row[field]),
      do: raise("#{row["id"] || "row"}: invalid #{field} #{inspect(row[field])}")
  end

  defp positive_integer!(value, label) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> :ok
      _ -> raise "#{label} must be a positive integer"
    end
  end

  defp date_string!(value, label) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      _ -> raise "#{label} must use YYYY-MM-DD"
    end
  end

  defp batch!(value) do
    unless Regex.match?(~r/^EXQ-B-\d{8}-\d{2,}$/, value),
      do: raise("invalid batch ID #{inspect(value)}")
  end

  defp evidence_id!(value) do
    unless Regex.match?(~r/^EXQ-E-\d{4,}$/, value),
      do: raise("invalid evidence ID #{inspect(value)}")
  end
end

KataExQuality.Backlog.main(System.argv())
