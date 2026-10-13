{:ok, _} = NervesGate.TestDevice.start()
ExUnit.start(exclude: [:integration, :hardware])
