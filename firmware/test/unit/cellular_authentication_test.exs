defmodule NervesGate.Network.CellularAuthenticationTest do
  use ExUnit.Case, async: true
  alias NervesGate.Network.{Cellular, CellularAuthentication}

  @key ["cellular", "authentication"]
  @credentials %{apn: "internet.example", username: "example-user", password: "example-password"}
  @context {:ok, [~s(+CGDCONT: 1,"IP","internet.example","0.0.0.0",0,0)]}

  setup do
    table = :"cellular_authentication_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), Atom.to_string(table))
    on_exit(fn -> File.rm_rf!(dir) end)
    start = fn -> start_supervised!({PropertyTable, name: table, persist_data_path: dir}) end
    start.()
    %{table: table, start: start}
  end

  test "PAP uses the verified context's APN and Quectel authentication mode 1" do
    assert CellularAuthentication.command(@credentials, @context, 1) ==
             {:ok, ~s(AT+QICSGP=1,1,"internet.example","example-user","example-password",1)}

    other_context = {:ok, [~s(+CGDCONT: 2,"IP","internet.example","0.0.0.0",0,0)]}
    assert {:ok, command} = CellularAuthentication.command(@credentials, other_context, 2)
    assert command =~ "AT+QICSGP=2,1,"
  end

  test "switching APNs clears stale modem credentials, never reuses another APN's PAP" do
    other = {:ok, [~s(+CGDCONT: 1,"IP","other.example","0.0.0.0",0,0)]}

    assert CellularAuthentication.command(@credentials, other, 1) ==
             {:ok, ~s(AT+QICSGP=1,1,"other.example","","",0)}
  end

  test "absent or forgotten credentials explicitly clear the modem's saved authentication" do
    assert CellularAuthentication.command(nil, @context, 1) ==
             {:ok, ~s(AT+QICSGP=1,1,"internet.example","","",0)}

    blank = {:ok, [~s(+CGDCONT: 1,"IP","","0.0.0.0",0,0)]}

    assert CellularAuthentication.command(nil, blank, 1) ==
             {:ok, ~s(AT+QICSGP=1,1,"","","",0)}
  end

  test "unknown, foreign or unsafe contexts fail closed without a credential command" do
    for response <- [
          {:error, :timeout},
          {:ok, []},
          {:ok, [~s(+CGDCONT: 8,"IP","internet.example","0.0.0.0",0,0)]},
          {:ok, [~s(+CGDCONT: 1,"IPV4V6","internet.example","",0,0)]},
          {:ok, [~s(+CGDCONT: 1,"IP","bad\rAT+CFUN=0","",0,0)]}
        ],
        record <- [nil, @credentials] do
      assert CellularAuthentication.command(record, response, 1) ==
               {:error, :cellular_authentication_failed}
    end

    assert CellularAuthentication.command(@credentials, @context, 9) ==
             {:error, :cellular_authentication_failed}
  end

  test "backend admission bounds credentials and rejects AT quoting and control injection" do
    assert Cellular.parameters(:save_authentication, ["internet.example", "user", ""]) == :ok

    assert Cellular.parameters(:save_authentication, ["internet.example", "user@realm", "a,b ; !"]) ==
             :ok

    assert Cellular.parameters(:forget_authentication, []) == :ok

    for {apn, username, password} <- [
          {"", "user", "password"},
          {"internet.example", "", "password"},
          {"internet.example", "user\"\rAT+CFUN=0", "password"},
          {"internet.example", "user", "quote\""},
          {"internet.example", "user", "back\\slash"},
          {"internet.example", "user", "line\nfeed"},
          {"internet.example", "user", <<0>>},
          {"internet.example", "user", <<255>>},
          {"internet.example", String.duplicate("a", 65), "password"},
          {"internet.example", "user", String.duplicate("a", 65)},
          {nil, "user", "password"},
          {"internet.example", nil, "password"}
        ] do
      assert Cellular.parameters(:save_authentication, [apn, username, password]) ==
               {:error, :cellular_authentication_parameters}
    end
  end

  test "private credentials persist, while metadata contains neither username nor password",
       context do
    assert CellularAuthentication.load(context.table) == {:ok, nil}

    assert CellularAuthentication.save(
             @credentials.apn,
             @credentials.username,
             @credentials.password,
             context.table
           ) == :ok

    restart(context)
    assert CellularAuthentication.load(context.table) == {:ok, @credentials}

    assert CellularAuthentication.metadata(context.table) == %{
             authentication: :pap,
             authentication_apn: "internet.example"
           }

    refute inspect(CellularAuthentication.metadata(context.table)) =~ @credentials.username
    refute inspect(CellularAuthentication.metadata(context.table)) =~ @credentials.password
  end

  test "forget removes credentials across a restart", context do
    assert CellularAuthentication.save(
             @credentials.apn,
             @credentials.username,
             @credentials.password,
             context.table
           ) == :ok

    assert CellularAuthentication.forget(context.table) == :ok
    restart(context)
    assert CellularAuthentication.load(context.table) == {:ok, nil}

    assert CellularAuthentication.metadata(context.table) == %{
             authentication: :none,
             authentication_apn: nil
           }
  end

  test "invalid records fail closed and invalid writes leave the prior record alone", %{
    table: table
  } do
    assert CellularAuthentication.save("internet.example", "user", "password", table) == :ok

    assert CellularAuthentication.save("internet.example", "user", "bad\n", table) ==
             {:error, :cellular_authentication_parameters}

    assert {:ok, %{password: "password"}} = CellularAuthentication.load(table)

    PropertyTable.put(table, @key, %{apn: "internet.example", username: "user", password: "bad\n"})

    assert CellularAuthentication.load(table) == {:error, :cellular_authentication_storage}
    assert CellularAuthentication.metadata(table).authentication == :unknown
  end

  test "log filtering redacts PAP commands, maps and function arguments" do
    event = %{
      msg:
        {:report,
         %{
           command: ~s(AT+QICSGP=1,1,"internet.example","example-user","example-password",1),
           credentials: @credentials,
           args:
             {CellularAuthentication, :save,
              ["internet.example", "example-user", "example-password"]},
           last_message: {:cellular, :save_authentication, Map.values(@credentials)}
         }}
    }

    filtered = inspect(Cellular.filter_log(event, nil))
    refute filtered =~ @credentials.username
    refute filtered =~ @credentials.password
    assert filtered =~ "REDACTED CELLULAR COMMAND"
  end

  defp restart(%{table: table, start: start}) do
    :ok = stop_supervised(table)
    start.()
  end
end
