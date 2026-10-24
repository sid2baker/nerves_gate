defmodule Workbench.SSHClientTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "host verification uses the requested DNS name, rejecting unknown or changed keys", %{
    tmp_dir: dir
  } do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    contents = :ssh_file.encode([{public, [hostnames: [~c"controller.example"]]}], :known_hosts)
    path = Path.join(dir, "known_hosts")
    File.write!(path, contents)
    peer = [~c"100.125.110.96", {100, 125, 110, 96}]

    options = [
      user_dir: to_charlist(dir),
      key_cb_private: [host: ~c"controller.example", agent: false]
    ]

    refute :ssh_file.is_host_key(public, peer, 22, :"ssh-rsa", options)
    assert Workbench.SSHHostKeys.is_host_key(public, peer, 22, :"ssh-rsa", options)
    unknown = Keyword.put(options, :key_cb_private, host: ~c"unknown.example", agent: false)
    refute Workbench.SSHHostKeys.is_host_key(public, peer, 22, :"ssh-rsa", unknown)
    changed = {:RSAPublicKey, elem(public, 1) + 2, elem(public, 2)}
    refute Workbench.SSHHostKeys.is_host_key(changed, peer, 22, :"ssh-rsa", options)
    refute Workbench.SSHHostKeys.is_host_key(public, peer, 2222, :"ssh-rsa", options)

    assert {:error, :host_key_not_accepted} =
             Workbench.SSHHostKeys.add_host_key(~c"unknown.example", 22, public, options)

    assert File.read!(path) == contents
  end
end
