defmodule WhisprCalls.Workers.RoomReconciler do
  @moduledoc """
  GenServer periodique qui reconcilie l'etat des rooms LiveKit avec la DB.

  Toutes les `reconciler_interval_ms` (defaut 5 min), il charge les calls
  en status `active` (ringing ou connected) crees depuis plus de 60 minutes
  et verifie leur existence cote LiveKit via `ListRooms`.

  - Room absente cote LiveKit + DB pense active → finalise le call avec
    `end_reason: "reconciler_orphan"`.
  - Room presente cote LiveKit + DB pense ended → log warn uniquement
    (orphan LiveKit-side, hors scope de ce reconciler).

  Le worker est desactive en test (via `:reconciler_enabled` = false) pour
  ne pas interferer avec le SQL sandbox.
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias WhisprCalls.Calls.{Call, LiveKitClient}
  alias WhisprCalls.Repo

  # Anciennete minimale d'un call actif pour etre examine (en secondes).
  # 60 min : evite de flaguer des calls legitimes encore en cours.
  @orphan_age_seconds 3_600

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if reconciler_enabled?() do
      schedule_tick(interval_ms())
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    reconcile()
    schedule_tick(interval_ms())
    {:noreply, state}
  end

  @doc """
  Lance une passe de reconciliation : charge les calls actifs anciens,
  interroge LiveKit et finalise les orphelins DB. Idempotent et safe
  a appeler manuellement depuis IEx ou les tests.
  """
  @spec reconcile() :: :ok
  def reconcile do
    cutoff = DateTime.add(DateTime.utc_now(), -@orphan_age_seconds, :second)

    active_calls =
      Call
      |> where([c], c.status in ["ringing", "connected"] and c.started_at < ^cutoff)
      |> Repo.all()

    if active_calls == [] do
      Logger.debug("RoomReconciler: aucun call actif ancien, rien a faire")
      :ok
    else
      Logger.info("RoomReconciler: #{length(active_calls)} call(s) actif(s) anciens a verifier")

      case LiveKitClient.list_rooms() do
        {:ok, live_rooms} ->
          process_calls(active_calls, live_rooms)

        {:error, reason} ->
          Logger.error("RoomReconciler: impossible de lister les rooms LiveKit: #{inspect(reason)}")
          :ok
      end
    end
  rescue
    err ->
      Logger.error("RoomReconciler: tick echoue: #{inspect(err)}")
      :ok
  end

  # Compare chaque call DB avec la liste des rooms LiveKit.
  # room_names est un MapSet de noms de rooms actives cote LiveKit.
  defp process_calls(calls, live_rooms) do
    room_names = MapSet.new(live_rooms)

    Enum.each(calls, fn call ->
      cond do
        not MapSet.member?(room_names, call.livekit_room) ->
          # Room absente LiveKit : orphelin DB - a finaliser
          Logger.warning(
            "RoomReconciler: call #{call.id} (room=#{call.livekit_room}) absent LiveKit, finalisation"
          )

          finalize_orphan(call)

        true ->
          # Room presente : call legitime ou fin imminente, on ne touche pas
          Logger.debug(
            "RoomReconciler: call #{call.id} room=#{call.livekit_room} encore active LiveKit, skip"
          )
      end
    end)

    :ok
  end

  defp finalize_orphan(%Call{} = call) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, call.connected_at || call.started_at, :second)

    result =
      call
      |> Call.changeset(%{
        status: "ended",
        ended_at: now,
        duration_seconds: duration,
        end_reason: "reconciler_orphan"
      })
      |> Repo.update()

    case result do
      {:ok, _updated} ->
        Logger.info("RoomReconciler: call #{call.id} finalise (reconciler_orphan)")

      {:error, changeset} ->
        Logger.error(
          "RoomReconciler: echec finalisation call #{call.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp interval_ms do
    Application.get_env(:whispr_calls, :reconciler_interval_ms, 300_000)
  end

  defp reconciler_enabled? do
    Application.get_env(:whispr_calls, :reconciler_enabled, true)
  end
end
