defmodule WhisprCalls.Events.PublisherTestRecorder do
  @moduledoc """
  Test-only Publisher that broadcasts events on Phoenix.PubSub instead of
  Redis. Tests can subscribe via `subscribe/0` and assert on received
  messages with `assert_receive {:published, channel, payload}`.
  """
  @behaviour WhisprCalls.Events.Publisher

  @topic "test:events_publisher"

  @impl true
  def publish(channel, payload) when is_binary(channel) and is_map(payload) do
    Phoenix.PubSub.broadcast(WhisprCalls.PubSub, @topic, {:published, channel, payload})
    :ok
  end

  @doc """
  Subscribe the calling test process to the published events topic.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(WhisprCalls.PubSub, @topic)
  end
end
