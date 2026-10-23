defmodule Dev.SessionTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "an unavailable socket outside the working directory does not crash status checks", %{
    tmp_dir: tmp_dir
  } do
    dir = Path.expand(Path.join(tmp_dir, String.duplicate("session", 12)))
    cwd = Path.join(dir, "checkout/firmware")
    File.mkdir_p!(cwd)
    socket = Path.join(dir, "http.sock")
    File.write!(socket, "stale")
    assert byte_size(socket) > 107

    File.cd!(cwd, fn ->
      # An absolute Unix socket address this long makes gen_tcp exit(:badarg).
      # Traversing up to the session keeps its address short and usable.
      assert Path.relative_to_cwd(socket) == socket
      assert Dev.Session.connect(dir, 1_000) == nil
    end)
  end
end
