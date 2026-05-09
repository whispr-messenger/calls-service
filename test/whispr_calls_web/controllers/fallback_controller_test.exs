defmodule WhisprCallsWeb.FallbackControllerTest do
  @moduledoc """
  Couvre directement les clauses `call/2` du FallbackController. On invoque
  le plug avec une conn de base et on inspecte le status + le corps JSON
  decode pour chaque cas d'erreur. Cela evite de seeder un cas reel pour
  chaque type d'erreur (certains comme `:invalid_request` du changeset
  sont quasi impossibles a declencher via le controller dans l'etat
  actuel du contexte).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  alias WhisprCallsWeb.FallbackController

  defp run(error) do
    conn = conn(:get, "/")
    FallbackController.call(conn, error)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test ":not_found -> 404" do
    conn = run({:error, :not_found})
    assert conn.status == 404
    assert decode(conn) == %{"error" => "not_found"}
  end

  test ":call_not_found -> 404" do
    conn = run({:error, :call_not_found})
    assert conn.status == 404
    assert decode(conn) == %{"error" => "not_found"}
  end

  test ":forbidden -> 403" do
    conn = run({:error, :forbidden})
    assert conn.status == 403
    assert decode(conn) == %{"error" => "forbidden"}
  end

  test ":not_invited -> 403" do
    conn = run({:error, :not_invited})
    assert conn.status == 403
    assert decode(conn) == %{"error" => "not_invited"}
  end

  test ":not_participant -> 403" do
    conn = run({:error, :not_participant})
    assert conn.status == 403
    assert decode(conn) == %{"error" => "not_participant"}
  end

  test ":not_member -> 403" do
    conn = run({:error, :not_member})
    assert conn.status == 403
    assert decode(conn) == %{"error" => "not_member"}
  end

  test ":invitee_not_member -> 403" do
    conn = run({:error, :invitee_not_member})
    assert conn.status == 403
    assert decode(conn) == %{"error" => "invitee_not_member"}
  end

  test ":already_joined_or_declined -> 409" do
    conn = run({:error, :already_joined_or_declined})
    assert conn.status == 409
    assert decode(conn) == %{"error" => "already_resolved"}
  end

  test ":call_already_ended -> 410" do
    conn = run({:error, :call_already_ended})
    assert conn.status == 410
    assert decode(conn) == %{"error" => "call_already_ended"}
  end

  test ":call_not_ringing -> 409" do
    conn = run({:error, :call_not_ringing})
    assert conn.status == 409
    assert decode(conn) == %{"error" => "call_not_ringing"}
  end

  test ":participant_not_invited -> 409" do
    conn = run({:error, :participant_not_invited})
    assert conn.status == 409
    assert decode(conn) == %{"error" => "participant_not_invited"}
  end

  test ":invalid_request -> 422" do
    conn = run({:error, :invalid_request})
    assert conn.status == 422
    assert decode(conn) == %{"error" => "invalid_request"}
  end

  test "Ecto.Changeset -> 422" do
    changeset = %Ecto.Changeset{valid?: false}
    conn = run({:error, changeset})
    assert conn.status == 422
    assert decode(conn) == %{"error" => "validation_failed"}
  end

  test "unknown atom error -> 500 generic, ne fuit pas la raison" do
    import ExUnit.CaptureLog

    log =
      capture_log(fn ->
        conn = run({:error, :something_unexpected})
        assert conn.status == 500
        assert decode(conn) == %{"error" => "internal_server_error"}
      end)

    # la raison reelle doit etre loggee cote serveur, pas exposee au client
    assert log =~ "something_unexpected"
  end

  test "unknown tuple error -> 500 generic, ne fuit pas la struct" do
    import ExUnit.CaptureLog

    log =
      capture_log(fn ->
        conn = run({:error, {:db_failure, %{secret: "leak"}}})
        assert conn.status == 500
        assert decode(conn) == %{"error" => "internal_server_error"}
        refute decode(conn)["error"] =~ "leak"
      end)

    assert log =~ "db_failure"
  end
end
