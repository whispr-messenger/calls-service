defmodule WhisprCalls.Events.Publisher do
  @moduledoc """
  Publishes call events to Redis pub/sub so messaging-service can fan-out
  to clients.

  Dispatches through `WhisprCalls.Events.Publisher.Redis` in prod and a
  Mox in tests so we can assert publishes without a live Redis.
  """
  @callback publish(channel :: String.t(), payload :: map()) :: :ok | {:error, term()}

  def publish(channel, payload) when is_binary(channel) and is_map(payload) do
    impl().publish(channel, payload)
  end

  defp impl,
    do: Application.get_env(:whispr_calls, :events_publisher, __MODULE__.Redis)
end

defmodule WhisprCalls.Events.Publisher.Redis do
  @moduledoc false
  @behaviour WhisprCalls.Events.Publisher
  require Logger

  @impl true
  def publish(channel, payload) do
    case Redix.command(:redix, ["PUBLISH", channel, Jason.encode!(payload)]) do
      {:ok, _subscribers} ->
        :ok

      {:error, err} ->
        Logger.error("redis publish failed: #{inspect(err)}")
        {:error, err}
    end
  end
end
