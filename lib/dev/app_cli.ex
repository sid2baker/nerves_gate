defmodule Dev.AppCLI do
  @moduledoc false
  def run(command, args) do
    {options, paths} = OptionParser.parse!(args, strict: [device: :string, local_sdk: :boolean])

    path =
      case paths do
        [path] -> Path.expand(path)
        _ -> raise ArgumentError, "Usage: mix app.#{command} APP_DIRECTORY [--device ID]"
      end

    case command do
      :new ->
        app = Dev.Applications.new!(path, options[:local_sdk] || false)
        IO.puts("Created #{app.path}")

        if session = Dev.Session.connect() do
          {client, _} = session
          Req.post!(client, url: "/api/application", form: [action: "open", path: app.path])
        end

      :test ->
        Dev.Applications.test!(path)

      :package ->
        IO.puts(Dev.Applications.package!(path))

      :install ->
        install(path, options[:device])
    end
  end

  defp install(path, device) do
    {client, state} =
      Dev.Session.connect() ||
        raise(ArgumentError, "Start mix dev and its simulated devices first")

    device =
      device ||
        case state["lifecycle"]["devices"] do
          [%{"id" => id}] -> id
          _ -> raise ArgumentError, "Select --device"
        end

    package = Dev.Applications.package!(path, fn _ -> :ok end, :temporary)

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
