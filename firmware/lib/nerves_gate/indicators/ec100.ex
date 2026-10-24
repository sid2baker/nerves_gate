defmodule NervesGate.Indicators.EC100 do
  @moduledoc "EC100 RUN/USER1/USER2 LEDs (1 = on) and gpio-keys. Never changes kernel triggers."
  import Bitwise

  @leds %{run: "ec100:run", user1: "ec100:user1", user2: "ec100:user2"}

  def read_led(led, root) do
    path = Path.join(root, Map.fetch!(@leds, led))

    with :ok <- manual(path),
         {:ok, "1"} <- read(path, "max_brightness"),
         {:ok, value} when value in ["0", "1"] <- read(path, "brightness") do
      {:ok, String.to_integer(value)}
    else
      _ ->
        {:error,
         %{
           code: "led_unavailable",
           message: "A status LED is unavailable or controlled by a kernel trigger."
         }}
    end
  end

  def write_led(led, value, root) when value in [0, 1] do
    path = Path.join([root, Map.fetch!(@leds, led), "brightness"])

    with {:ok, _} <- read_led(led, root),
         :ok <- File.write(path, Integer.to_string(value)),
         {:ok, ^value} <- read_led(led, root) do
      :ok
    else
      _ ->
        {:error,
         %{
           code: "led_unavailable",
           message: "A status LED is unavailable or controlled by a kernel trigger."
         }}
    end
  end

  def open_button(receiver, _context) do
    with {:ok, path} <- button_path(),
         {:ok, pid} <- InputEvent.start_link(path: path, receiver: receiver) do
      {:ok, pid, path}
    else
      _ ->
        {:error, %{code: "button_unavailable", message: "The EC100 user button is unavailable."}}
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
      [entry] ->
        {:ok, "/dev/input/" <> Path.basename(entry)}

      _ ->
        {:error, %{code: "button_unavailable", message: "The EC100 user button is unavailable."}}
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
