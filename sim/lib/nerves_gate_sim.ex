defmodule NervesGateSim do
  @moduledoc "Owned QEMU devices and virtual hardware; no in-memory backend."
  @source_dir Path.expand("..", __DIR__)
  def source_dir, do: @source_dir
  def script(name), do: Path.join(@source_dir, "priv/qemu/#{name}.exs")
end
