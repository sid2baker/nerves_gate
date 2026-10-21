defmodule Dev.AppCLI do
  @moduledoc false
  def run(command, args) do
    {options, names} = OptionParser.parse!(args, strict: [solution: :string, device: :string])

    solution =
      if options[:solution],
        do: Dev.Solution.load!(options[:solution]),
        else: Dev.Solution.current!()

    if solution.warning, do: IO.puts(solution.warning)

    name =
      case names do
        [] -> nil
        [name] -> name
        _ -> raise ArgumentError, "Select at most one app"
      end

    case command do
      :new -> Dev.Solution.app_new!(solution, name || raise(ArgumentError, "Supply an app name"))
      :test -> Dev.Solution.test!(solution, name)
      :package -> IO.puts(Dev.Solution.package!(solution, name))
      :install -> install(solution, name, options[:device])
    end
  end

  defp install(solution, name, device) do
    {client, state} =
      Dev.Session.connect() ||
        raise(ArgumentError, "Start mix dev SOLUTION and its devices first")

    if get_in(state, ["solution", "path"]) != solution.path,
      do: raise(ArgumentError, "The running session has a different solution")

    device =
      device ||
        case state["lifecycle"]["devices"] do
          [%{"id" => id}] -> id
          _ -> raise ArgumentError, "Select --device"
        end

    package = Dev.Solution.package!(solution, name, fn _ -> :ok end, :temporary)

    try do
      case Req.post!(client, url: "/api/install", form: [device: device, package: package]) do
        %{status: 200, body: %{"id" => id}} -> Dev.QemuCLI.wait(client, id, MapSet.new())
        %{body: %{"error" => message}} -> raise message
        _ -> raise "Install outcome unknown; inspect the device page before retrying"
      end
    after
      File.rm(package)
    end
  end
end
