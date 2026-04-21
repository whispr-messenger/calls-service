defmodule WhisprCalls.Events.Publisher do
  @moduledoc false
  require Logger

  def publish(channel, payload) when is_map(payload) do
    case Redix.command(:redix, ["PUBLISH", channel, Jason.encode!(payload)]) do
      {:ok, _subscribers} ->
        :ok

      {:error, err} ->
        Logger.error("redis publish failed: #{inspect(err)}")
        {:error, err}
    end
  end
end
