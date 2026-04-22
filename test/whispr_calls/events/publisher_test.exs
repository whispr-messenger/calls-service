defmodule WhisprCalls.Events.PublisherTest do
  use ExUnit.Case, async: true

  alias WhisprCalls.Events.Publisher

  describe "publish/2" do
    test "returns :ok when redis accepts the message" do
      # The test container has a redis running on :redix.
      assert :ok = Publisher.publish("whispr:calls:test", %{hello: "world"})
    end
  end
end
