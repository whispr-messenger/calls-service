Mox.defmock(WhisprCalls.Calls.LiveKitClientMock, for: WhisprCalls.Calls.LiveKitClient)
Application.put_env(:whispr_calls, :livekit_client, WhisprCalls.Calls.LiveKitClientMock)

Mox.defmock(WhisprCalls.Grpc.MessagingClientMock, for: WhisprCalls.Grpc.MessagingClient)
# Default to the Stub (allow-all) so the rest of the suite keeps its
# happy-path behaviour. Individual tests that want to assert not-member
# swap in MessagingClientMock explicitly.
Application.put_env(:whispr_calls, :messaging_client, WhisprCalls.Grpc.MessagingClient.Stub)

Mox.defmock(WhisprCalls.Services.UserServiceMock, for: WhisprCalls.Services.UserServiceBehaviour)
# Default au Stub (jamais bloque) pour le happy-path. Les tests qui veulent
# asserter le refus sur blocage swappent UserServiceMock explicitement.
Application.put_env(:whispr_calls, :user_service_client, WhisprCalls.Services.UserService.Stub)

# Default events publisher in tests: broadcasts to Phoenix.PubSub so tests
# can subscribe with `WhisprCalls.Events.PublisherTestRecorder.subscribe()`
# and `assert_receive` published events. Avoids depending on a live Redis.
Application.put_env(
  :whispr_calls,
  :events_publisher,
  WhisprCalls.Events.PublisherTestRecorder
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(WhisprCalls.Repo, :manual)
