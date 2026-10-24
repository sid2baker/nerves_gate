defmodule Workbench.TargetBuild do
  @moduledoc "Reject workstation-linked native ports in x86_64 firmware builds."

  def verify!(root) do
    for {app, name} <- [{"vintage_net", "if_monitor"}, {"nerves_uevent", "uevent"}] do
      path = Path.join([root, "firmware/_build/x86_64_dev/lib", app, "priv", name])

      unless interpreter(File.read!(path)) == "/lib/ld-musl-x86_64.so.1",
        do:
          raise(
            "#{path} is not a musl target executable; clean the target build and initialize Nerves before compiling"
          )
    end

    :ok
  end

  def interpreter(
        <<0x7F, "ELF", 2, 1, _::binary-size(10), _::16, 62::little-16, _::32, _::64,
          offset::little-64, _::64, _::32, _::16, size::little-16, count::little-16, _::binary>> =
          binary
      )
      when count > 0 and size >= 56 do
    Enum.find_value(0..(count - 1), fn index ->
      case binary_part(binary, offset + index * size, size) do
        <<3::little-32, _::32, start::little-64, _::128, length::little-64, _::binary>> ->
          binary |> binary_part(start, length) |> String.trim_trailing(<<0>>)

        _ ->
          nil
      end
    end)
  rescue
    ArgumentError -> nil
  end

  def interpreter(_), do: nil
end
