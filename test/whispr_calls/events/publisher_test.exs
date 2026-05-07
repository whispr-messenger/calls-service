defmodule WhisprCalls.Events.PublisherTest do
  use ExUnit.Case, async: false

  alias WhisprCalls.Events.Publisher

  describe "publish/2 (default test impl: PublisherTestRecorder)" do
    test "returns :ok when redis accepts the message" do
      # In the test env the configured impl is PublisherTestRecorder which
      # always returns :ok and forwards to subscribers via Phoenix.PubSub.
      assert :ok = Publisher.publish("whispr:calls:test", %{hello: "world"})
    end
  end

  describe "Publisher.Redis (real impl exercised against the local redis)" do
    test "returns :ok when redis accepts the message" do
      assert :ok = Publisher.Redis.publish("whispr:calls:test", %{hello: "world"})
    end
  end

  describe "publish/2 with a custom impl override" do
    test "delegates to the configured impl" do
      original = Application.get_env(:whispr_calls, :events_publisher)

      defmodule FakeImpl do
        @behaviour WhisprCalls.Events.Publisher
        @impl true
        def publish(_channel, _payload), do: {:error, :forced}
      end

      Application.put_env(:whispr_calls, :events_publisher, FakeImpl)
      on_exit(fn -> Application.put_env(:whispr_calls, :events_publisher, original) end)

      assert {:error, :forced} = Publisher.publish("c", %{})
    end
  end
end
