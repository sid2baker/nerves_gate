defmodule NervesGate.Indicators.EC100 do
  @moduledoc "EC100 run LED and gpio-keys button only. No direct GPIO access."
  import Bitwise

  @led "/sys/class/leds/ec100:run"

  def read_led(root \\ @led) do
    with :ok <- manual(root),
         {:ok, "1"} <- read(root, "max_brightness"),
         {:ok, value} when value in ["0", "1"] <- read(root, "brightness") do
      {:ok, String.to_integer(value)}
    else
      _ -> {:error, :led_unavailable}
    end
  end

  def write_led(value, root \\ @led) when value in [0, 1] do
    with {:ok, _} <- read_led(root),
         :ok <- File.write(Path.join(root, "brightness"), Integer.to_string(value)),
         {:ok, ^value} <- read_led(root) do
      :ok
    else
      _ -> {:error, :led_unavailable}
    end
  end

  def open_button(receiver, _context) do
    with {:ok, path} <- button_path(),
         {:ok, pid} <- InputEvent.start_link(path: path, receiver: receiver) do
      {:ok, pid, path}
    else
      _ -> {:error, :button_unavailable}
    end
  end

  # Input numbering is not stable. Match the gpio-keys name AND KEY_PROG1.
  # The EC100 runs a 32-bit kernel, whose capability bitmap uses 32-bit words.
  def button_path(root \\ "/sys/class/input") do
    matches =
      root
      |> Path.join("event*")
      |> Path.wildcard()
      |> Enum.filter(fn entry ->
        with {:ok, "gpio-keys"} <- read(entry, "device/name"),
             {:ok, bitmap} <- read(entry, "device/capabilities/key") do
          prog1?(bitmap)
        else
          _ -> false
        end
      end)

    case matches do
      [entry] -> {:ok, "/dev/input/" <> Path.basename(entry)}
      _ -> {:error, :button_unavailable}
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

  # Never take over a kernel-triggered LED or change its trigger.
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
