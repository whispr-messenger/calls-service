Mox.defmock(WhisprCalls.Calls.LiveKitClientMock, for: WhisprCalls.Calls.LiveKitClient)
Application.put_env(:whispr_calls, :livekit_client, WhisprCalls.Calls.LiveKitClientMock)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(WhisprCalls.Repo, :manual)
