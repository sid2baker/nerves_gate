defmodule NervesGate.Indicators.Sysfs do
  @moduledoc """
  Board LEDs (1 = on) by Linux LED name, and a named KEY_PROG1 input button.
  Never changes kernel triggers.
  """
  import Bitwise

  def read_led(name, root \\ "/sys/class/leds") do
    path = Path.join(root, name)

    with :ok <- manual(path),
         {:ok, "1"} <- read(path, "max_brightness"),
         {:ok, value} when value in ["0", "1"] <- read(path, "brightness") do
      {:ok, String.to_integer(value)}
    else
      _ -> :error
    end
  end

  def write_led(name, value, root \\ "/sys/class/leds") when value in [0, 1] do
    with {:ok, _} <- read_led(name, root),
         :ok <- File.write(Path.join([root, name, "brightness"]), Integer.to_string(value)),
         {:ok, ^value} <- read_led(name, root) do
      :ok
    else
      _ -> :error
    end
  end

  def open_button(receiver, name) do
    with {:ok, path} <- button_path(name),
         {:ok, pid} <- InputEvent.start_link(path: path, receiver: receiver) do
      {:ok, pid, path}
    else
      _ -> :error
    end
  end

  # Input numbering is not stable. Match the board's input name AND KEY_PROG1,
  # the button code declared by these systems. RK3506 uses 32-bit bitmap words.
  def button_path(name, root \\ "/sys/class/input") do
    matches =
      root
      |> Path.join("event*")
      |> Path.wildcard()
      |> Enum.filter(fn entry ->
        with {:ok, ^name} <- read(entry, "device/name"),
             {:ok, bitmap} <- read(entry, "device/capabilities/key") do
          prog1?(bitmap)
        else
          _ -> false
        end
      end)

    case matches do
      [entry] -> {:ok, "/dev/input/" <> Path.basename(entry)}
      _ -> :error
    end
  end

  defp prog1?(bitmap) do
    bitmap
    |> String.split()
    |> Enum.reverse()
    |> Enum.at(div(148, 32), "0")
    |> Integer.parse(16)
    |> case do
      {word, ""} -> (word &&& 1 <<< rem(148, 32)) != 0
      _ -> false
    end
  end

  defp manual(root) do
    case read(root, "trigger") do
      {:ok, triggers} -> if "[none]" in String.split(triggers), do: :ok, else: :error
      {:error, :enoent} -> :ok
      _ -> :error
    end
  end

  defp read(root, file) do
    case File.read(Path.join(root, file)) do
      {:ok, value} -> {:ok, String.trim(value)}
      error -> error
    end
  end
end
