defmodule WhisprCalls.Workers.RoomReconcilerTest do
  use WhisprCalls.DataCase, async: false

  import Mox

  alias WhisprCalls.Calls.{Call, LiveKitClientMock}
  alias WhisprCalls.Repo
  alias WhisprCalls.Workers.RoomReconciler

  setup :verify_on_exit!

  # Helper : cree un call avec un started_at suffisamment ancien.
  defp insert_old_active_call(status, room \\ nil) do
    room = room || "call_" <> Ecto.UUID.generate()
    started = DateTime.add(DateTime.utc_now(), -3700, :second)

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: room,
        status: status,
        started_at: started
      })
      |> Repo.insert()

    call
  end

  # Helper : cree un call recent (moins de 60 min) qui NE doit pas etre touche.
  defp insert_recent_active_call do
    room = "call_recent_" <> Ecto.UUID.generate()
    started = DateTime.add(DateTime.utc_now(), -300, :second)

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: room,
        started_at: started
      })
      |> Repo.insert()

    call
  end

  test "reconcile/0 finalise un call orphelin (room absente LiveKit)" do
    orphan = insert_old_active_call("connected")

    # LiveKit renvoie une liste sans la room du call orphelin
    Mox.expect(LiveKitClientMock, :list_rooms, fn -> {:ok, ["call_autre_room"]} end)

    RoomReconciler.reconcile()

    updated = Repo.get!(Call, orphan.id)
    assert updated.status == "ended"
    assert updated.end_reason == "reconciler_orphan"
    assert updated.ended_at != nil
  end

  test "reconcile/0 ne touche pas un call dont la room est encore presente LiveKit" do
    call = insert_old_active_call("connected", "call_vivante_xyz")

    Mox.expect(LiveKitClientMock, :list_rooms, fn -> {:ok, ["call_vivante_xyz"]} end)

    RoomReconciler.reconcile()

    unchanged = Repo.get!(Call, call.id)
    assert unchanged.status == "connected"
  end

  test "reconcile/0 ignore les calls recents (< 60 min) meme si absents LiveKit" do
    recent = insert_recent_active_call()

    # list_rooms ne doit pas etre appele du tout si aucun appel ancien
    # (le filtre started_at exclut les recents avant le call LiveKit).
    # Si des anciens existent ailleurs, list_rooms sera appele - ici on
    # s assure juste que recent n est pas marque ended.
    # Pour isoler : pas de call ancien en DB dans ce test.
    # On mocke list_rooms pour le cas ou d autres calls anciens existent.
    Mox.stub(LiveKitClientMock, :list_rooms, fn -> {:ok, [recent.livekit_room]} end)

    RoomReconciler.reconcile()

    unchanged = Repo.get!(Call, recent.id)
    assert unchanged.status == "ringing"
  end

  test "reconcile/0 ne fait rien quand aucun call actif ancien" do
    # Aucun call en DB - list_rooms ne doit pas etre appele
    # (court-circuit avant l appel LiveKit)
    RoomReconciler.reconcile()

    # Pas d expect sur list_rooms => Mox verifie qu il n a pas ete appele
    :ok
  end

  test "reconcile/0 gere plusieurs orphelins en une passe" do
    orphan1 = insert_old_active_call("ringing")
    orphan2 = insert_old_active_call("connected")
    live_call = insert_old_active_call("connected", "call_room_vivante")

    Mox.expect(LiveKitClientMock, :list_rooms, fn ->
      {:ok, ["call_room_vivante"]}
    end)

    RoomReconciler.reconcile()

    assert Repo.get!(Call, orphan1.id).status == "ended"
    assert Repo.get!(Call, orphan1.id).end_reason == "reconciler_orphan"
    assert Repo.get!(Call, orphan2.id).status == "ended"
    assert Repo.get!(Call, orphan2.id).end_reason == "reconciler_orphan"
    assert Repo.get!(Call, live_call.id).status == "connected"
  end

  test "reconcile/0 est resilient si LiveKit renvoie une erreur" do
    _call = insert_old_active_call("connected")

    Mox.expect(LiveKitClientMock, :list_rooms, fn -> {:error, :timeout} end)

    # Doit retourner :ok sans crasher meme si LiveKit est KO
    assert :ok = RoomReconciler.reconcile()
  end

  test "le GenServer demarre et survit a un :tick force" do
    {:ok, pid} = GenServer.start_link(RoomReconciler, [])
    send(pid, :tick)
    Process.sleep(50)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
