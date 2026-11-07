#!/usr/bin/env elixir

defmodule CoverageTool do
  @moduledoc """
  Coverage analysis tool for Elixir projects.

  Commands:
    find [--commits N]     Find modules needing coverage, cross-referenced with recent git changes
    analyze <module_path>  Show detailed coverage for a specific module
    suggest                Show next unprocessed low-coverage modules (from tracker)
    mark <module_path>     Mark a module as processed
  """

  @processed_files_path ".coverage_progress.txt"
  @default_coverage_threshold 90.0

  def run(argv) do
    {root, threshold, args} =
      extract_options(argv, nil, @default_coverage_threshold, [])

    if root do
      File.cd!(root, fn -> main(args, threshold) end)
    else
      main(args, threshold)
    end
  end

  def main(["find" | opts], threshold) do
    commits = parse_commits_opt(opts, 30)
    find_modules(commits, threshold)
  end

  def main(["analyze", module_path], _threshold) do
    analyze_module(module_path)
  end

  def main(["suggest"], threshold) do
    suggest_next(threshold)
  end

  def main(["mark" | files], _threshold) when files != [] do
    mark_processed(files)
  end

  def main(_, _threshold) do
    IO.puts("""
    Usage:
      coverage.exs [--root DIR] [--threshold PERCENT] find [--commits N]
      coverage.exs [--root DIR] analyze <module_path>
      coverage.exs [--root DIR] [--threshold PERCENT] suggest
      coverage.exs [--root DIR] mark <path> [path...]
    """)
  end

  defp extract_options([], root, threshold, args),
    do: {root, threshold, Enum.reverse(args)}

  defp extract_options(["--root", root | rest], _current, threshold, args),
    do: extract_options(rest, root, threshold, args)

  defp extract_options(["--threshold", value | rest], root, _threshold, args),
    do: extract_options(rest, root, parse_threshold!(value), args)

  defp extract_options([arg | rest], root, threshold, args),
    do: extract_options(rest, root, threshold, [arg | args])

  defp parse_threshold!(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0.0 and number <= 100.0 -> number
      _ -> raise ArgumentError, "--threshold must be a number from 0 through 100"
    end
  end

  # --- Find Mode ---

  defp find_modules(commits, threshold) do
    with {:ok, coverage_data} <- load_coverage_data(),
         {:ok, git_files} <- get_recently_changed_files(commits) do
      modules = compute_module_stats(coverage_data)

      # Cross-reference with git changes
      results =
        git_files
        |> Enum.map(fn {git_path, change_count} ->
          case find_module(modules, git_path) do
            nil -> nil
            mod -> Map.put(mod, :recent_changes, change_count)
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn m -> m.percentage >= threshold end)
        |> Enum.sort_by(fn m -> m.percentage end)

      processed = read_processed_files()

      if results == [] do
        IO.puts("No recently-changed modules found below #{threshold}% coverage.")
      else
        IO.puts("FIND_RESULTS")
        IO.puts("commits_scanned=#{commits}")
        IO.puts("coverage_data_mtime=#{coverage_data_mtime()}")
        IO.puts("")
        IO.puts("MODULE|COVERAGE|COVERED|TOTAL|UNCOVERED|CHANGES|PROCESSED")

        Enum.each(results, fn m ->
          status = if m.name in processed, do: "yes", else: "no"

          IO.puts(
            "#{m.name}|#{m.percentage}|#{m.covered}|#{m.total}|#{m.uncovered_count}|#{m.recent_changes}|#{status}"
          )
        end)
      end
    else
      {:error, reason} -> IO.puts("ERROR: #{reason}")
    end
  end

  # --- Analyze Mode ---

  defp analyze_module(input_path) do
    with {:ok, coverage_data} <- load_coverage_data() do
      modules = compute_module_stats(coverage_data)
      normalized = normalize_path(input_path)

      case find_module(modules, normalized) do
        nil ->
          IO.puts("ERROR: Module not found in coverage data: #{input_path}")
          IO.puts("Tried matching: #{normalized}")

        mod ->
          IO.puts("ANALYZE_RESULT")
          IO.puts("module=#{mod.name}")
          IO.puts("filesystem_path=#{filesystem_path(mod.name)}")
          IO.puts("coverage=#{mod.percentage}")
          IO.puts("covered=#{mod.covered}")
          IO.puts("total=#{mod.total}")
          IO.puts("uncovered_count=#{mod.uncovered_count}")
          IO.puts("coverage_data_mtime=#{coverage_data_mtime()}")
          IO.puts("")

          if mod.uncovered_blocks != [] do
            IO.puts("UNCOVERED_BLOCKS")

            Enum.each(mod.uncovered_blocks, fn block ->
              first = List.first(block)
              last = List.last(block)

              if first == last do
                IO.puts("line:#{first}")
              else
                IO.puts("range:#{first}-#{last}")
              end
            end)
          end

          IO.puts("")
          IO.puts("UNCOVERED_LINES")
          Enum.each(mod.uncovered_lines, fn line -> IO.puts("#{line}") end)
      end
    else
      {:error, reason} -> IO.puts("ERROR: #{reason}")
    end
  end

  # --- Suggest Mode ---

  defp suggest_next(threshold) do
    with {:ok, coverage_data} <- load_coverage_data() do
      modules = compute_module_stats(coverage_data)
      processed = read_processed_files()

      candidates =
        modules
        |> Enum.reject(fn m -> m.name in processed end)
        |> Enum.reject(fn m -> m.percentage >= threshold end)
        |> Enum.reject(fn m -> m.uncovered_count < 5 end)
        |> Enum.sort_by(fn m -> m.percentage end)
        |> Enum.take(10)

      if candidates == [] do
        IO.puts("No unprocessed modules below #{threshold}% coverage with 5+ uncovered lines.")
      else
        IO.puts("SUGGEST_RESULTS")

        Enum.each(candidates, fn m ->
          IO.puts("#{m.name}|#{m.percentage}|#{m.covered}|#{m.total}|#{m.uncovered_count}")
        end)
      end
    else
      {:error, reason} -> IO.puts("ERROR: #{reason}")
    end
  end

  # --- Mark Mode ---

  defp mark_processed(files) do
    existing = read_processed_files()
    updated = Enum.uniq(existing ++ files)
    File.write!(@processed_files_path, Enum.join(updated, "\n"))
    IO.puts("Marked #{length(files)} file(s) as processed. Total: #{length(updated)}")
  end

  # --- Core Logic ---

  defp load_coverage_data do
    case coverage_json_paths() do
      [] -> load_html_coverage()
      paths -> load_json_coverage(paths)
    end
  end

  defp load_json_coverage(paths) do
    source_files =
      Enum.flat_map(paths, fn path ->
        case File.read(path) do
          {:ok, json} ->
            try do
              data = :json.decode(json)
              prefix_source_files(data["source_files"] || [], path)
            rescue
              e in ArgumentError -> throw({:invalid_json, path, e.message})
            end

          {:error, reason} ->
            throw({:read_error, path, reason})
        end
      end)

    {:ok, %{"source_files" => source_files}}
  catch
    {:invalid_json, path, message} -> {:error, "Invalid JSON in #{path}: #{message}"}
    {:read_error, path, reason} -> {:error, "Cannot read #{path}: #{reason}"}
  end

  defp prefix_source_files(source_files, coverage_path) do
    case Regex.run(~r{\Aapps/([^/]+)/cover/}, coverage_path) do
      [_, app] ->
        Enum.map(source_files, fn source ->
          Map.update!(source, "name", fn name ->
            if String.starts_with?(name, "apps/"), do: name, else: "apps/#{app}/#{name}"
          end)
        end)

      _ ->
        source_files
    end
  end

  defp load_html_coverage do
    files = coverage_html_paths()

    if files == [] do
      {:error,
       "No coverage data found. Run the project's coverage command, such as mix test --cover or mix coveralls.json."}
    else
      {:ok, %{"source_files" => Enum.map(files, &html_source_file/1)}}
    end
  end

  defp html_source_file(path) do
    html = File.read!(path)

    name =
      case Regex.run(~r{File generated from <code>(.*?)</code>}, html, capture: :all_but_first) do
        [source] -> source |> html_unescape() |> normalize_source_path()
        _ -> path
      end

    rows =
      Regex.scan(
        ~r{<tr class="(hit|miss)">\s*<td class="line" id="L(\d+)">}m,
        html,
        capture: :all_but_first
      )

    max_line =
      rows |> Enum.map(fn [_, line] -> String.to_integer(line) end) |> Enum.max(fn -> 0 end)

    row_map =
      Map.new(rows, fn [status, line] ->
        {String.to_integer(line), if(status == "hit", do: 1, else: 0)}
      end)

    coverage = if max_line == 0, do: [], else: Enum.map(1..max_line, &Map.get(row_map, &1, :null))

    %{"name" => name, "coverage" => coverage}
  end

  defp html_unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp normalize_source_path(path) do
    relative = Path.relative_to(path, File.cwd!())

    cond do
      not String.starts_with?(relative, "../") ->
        relative

      match = Regex.run(~r{(?:\A|/)((?:apps/[^/]+/)?(?:lib|test)/.*)\z}, path) ->
        candidate = List.last(match)
        if File.exists?(candidate), do: candidate, else: path

      true ->
        path
    end
  end

  defp compute_module_stats(%{"source_files" => source_files}) do
    source_files
    |> merge_source_files()
    |> Enum.filter(fn %{"name" => name} -> source_file?(name) end)
    |> Enum.map(fn %{"coverage" => coverage, "name" => name} ->
      {covered, total} =
        coverage
        |> Enum.reject(&(&1 in [:null, nil]))
        |> Enum.reduce({0, 0}, fn
          0, {c, t} -> {c, t + 1}
          _, {c, t} -> {c + 1, t + 1}
        end)

      percentage = if total > 0, do: Float.round(covered / total * 100, 1), else: 100.0

      uncovered_lines =
        coverage
        |> Enum.with_index(1)
        |> Enum.filter(fn {cov, _} -> cov == 0 end)
        |> Enum.map(fn {_, line} -> line end)

      uncovered_blocks = group_consecutive(uncovered_lines)

      %{
        name: name,
        percentage: percentage,
        covered: covered,
        total: total,
        uncovered_count: length(uncovered_lines),
        uncovered_lines: uncovered_lines,
        uncovered_blocks: uncovered_blocks
      }
    end)
  end

  defp merge_source_files(source_files) do
    source_files
    |> Enum.group_by(& &1["name"])
    |> Enum.map(fn {name, entries} ->
      coverages = Enum.map(entries, & &1["coverage"])
      max_length = coverages |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

      merged =
        if max_length == 0 do
          []
        else
          Enum.map(0..(max_length - 1), fn index ->
            values = Enum.map(coverages, &Enum.at(&1, index, :null))

            cond do
              Enum.any?(values, &is_number/1) and Enum.any?(values, &(&1 > 0)) -> 1
              Enum.any?(values, &(&1 == 0)) -> 0
              true -> :null
            end
          end)
        end

      %{"name" => name, "coverage" => merged}
    end)
  end

  defp source_file?(name) do
    File.exists?(name) and
      (String.starts_with?(name, "lib/") or String.contains?(name, "/lib/"))
  end

  defp group_consecutive([]), do: []

  defp group_consecutive(lines) do
    lines
    |> Enum.sort()
    |> Enum.reduce([], fn line, acc ->
      case acc do
        [[prev | _] = block | rest] when line == prev + 1 ->
          [[line | block] | rest]

        _ ->
          [[line] | acc]
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp find_module(modules, path) do
    path = normalize_path(path)

    Enum.find(modules, fn m ->
      m.name == path || String.ends_with?(m.name, "/#{path}") ||
        String.ends_with?(path, "/#{m.name}")
    end)
  end

  defp normalize_path(input) do
    input = String.trim(input)

    if module_name?(input) do
      find_module_source(input) || maybe_convert_module_name(input)
    else
      input
    end
  end

  defp module_name?(value),
    do: Regex.match?(~r/\A[A-Z][A-Za-z0-9_.]*\z/, value) and String.contains?(value, ".")

  defp find_module_source(module_name) do
    pattern = ~r/^\s*defmodule\s+#{Regex.escape(module_name)}\s+do(?:\s|$)/m

    (Path.wildcard("lib/**/*.ex") ++ Path.wildcard("apps/*/lib/**/*.ex"))
    |> Enum.find(fn path ->
      case File.read(path) do
        {:ok, source} -> Regex.match?(pattern, source)
        _ -> false
      end
    end)
  end

  defp maybe_convert_module_name(module_name) when is_binary(module_name) do
    if module_name?(module_name) do
      parts =
        module_name
        |> String.split(".")
        |> Enum.map(&Macro.underscore/1)

      "lib/" <> Enum.join(parts, "/") <> ".ex"
    else
      module_name
    end
  end

  defp filesystem_path(path) do
    matches = Path.wildcard("apps/*/#{path}")

    cond do
      File.exists?(path) -> path
      matches != [] -> List.first(matches)
      true -> path
    end
  end

  defp coverage_json_paths do
    (["cover/excoveralls.json", "cover/coverage.json"] ++
       Path.wildcard("apps/*/cover/excoveralls.json"))
    |> Enum.filter(&File.regular?/1)
  end

  defp coverage_html_paths do
    (Path.wildcard("cover/*.html") ++ Path.wildcard("apps/*/cover/*.html"))
    |> Enum.reject(&String.ends_with?(&1, "index.html"))
  end

  defp coverage_data_mtime do
    files = coverage_json_paths() ++ coverage_html_paths()

    files
    |> Enum.map(&file_mtime_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
    |> format_mtime()
  end

  defp file_mtime_value(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp format_mtime(nil), do: "unknown"

  defp format_mtime({{y, m, d}, {h, min, _s}}),
    do: "#{y}-#{pad(m)}-#{pad(d)} #{pad(h)}:#{pad(min)}"

  defp get_recently_changed_files(commits) do
    case System.cmd("git", ["log", "--name-only", "--pretty=format:", "-#{commits}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        files =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.ends_with?(&1, ".ex"))
          |> Enum.reject(&String.contains?(&1, "/test/"))
          |> Enum.frequencies()
          |> Enum.sort_by(fn {_, count} -> -count end)

        {:ok, files}

      {error, _} ->
        {:error, "git log failed: #{error}"}
    end
  end

  defp read_processed_files do
    case File.read(@processed_files_path) do
      {:ok, content} ->
        content |> String.split("\n") |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp parse_commits_opt([], default), do: default

  defp parse_commits_opt(["--commits", n | _], _default) do
    case Integer.parse(n) do
      {num, _} -> num
      :error -> 30
    end
  end

  defp parse_commits_opt([_ | rest], default), do: parse_commits_opt(rest, default)
end

CoverageTool.run(System.argv())
