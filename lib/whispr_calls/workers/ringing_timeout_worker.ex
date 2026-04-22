defmodule WhisprCalls.Workers.RingingTimeoutWorker do
  @moduledoc """
  Periodic GenServer that expires stale `ringing` calls.

  Every 5 seconds it scans the `calls` table for rows whose `status` is
  still `ringing` and whose `started_at` is older than 30 seconds, flips
  them to `missed` with `end_reason: "timeout"`, and publishes a Redis
  event so messaging-service can notify the initiator and recipients.

  The worker tolerates transient DB errors by logging them and moving on:
  the next tick will retry.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias WhisprCalls.Calls.Call
  alias WhisprCalls.Events.Publisher
  alias WhisprCalls.Repo

  @interval_ms 5_000
  @timeout_seconds 30

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    expire_stale_ringing()
    schedule_tick()
    {:noreply, state}
  end

  @doc """
  Expires ringing calls older than #{@timeout_seconds} seconds by flipping
  them to status `missed` and publishing a Redis event. Safe to call
  manually (e.g. from tests).
  """
  @spec expire_stale_ringing() :: :ok
  def expire_stale_ringing do
    cutoff = DateTime.add(DateTime.utc_now(), -@timeout_seconds, :second)

    Call
    |> where([c], c.status == "ringing" and c.started_at < ^cutoff)
    |> Repo.all()
    |> Enum.each(&mark_missed/1)

    :ok
  rescue
    err ->
      Logger.error("RingingTimeoutWorker tick failed: #{inspect(err)}")
      :ok
  end

  defp mark_missed(%Call{} = call) do
    case call
         |> Call.changeset(%{
           status: "missed",
           ended_at: DateTime.utc_now(),
           end_reason: "timeout"
         })
         |> Repo.update() do
      {:ok, updated} ->
        _ =
          Publisher.publish("whispr:calls:missed", %{
            call_id: updated.id,
            conversation_id: updated.conversation_id,
            timeout_seconds: @timeout_seconds
          })

        {:ok, updated}

      {:error, changeset} ->
        Logger.warning("failed to mark call missed: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval_ms)
end
