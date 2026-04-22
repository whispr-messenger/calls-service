defmodule WhisprCallsWeb.HealthControllerTest do
  use WhisprCallsWeb.ConnCase, async: false

  test "GET /health/live returns 200 ok", %{conn: conn} do
    resp = get(conn, "/health/live")
    assert %{"status" => "ok"} = json_response(resp, 200)
  end

  test "GET /health/ready returns 200 when db + redis reachable", %{conn: conn} do
    # The local test stack runs against the Docker compose postgres + redis,
    # both of which are required to even start the app. If the readiness
    # endpoint answers anything but 200 the deploy is broken anyway.
    resp = get(conn, "/health/ready")
    assert %{"status" => "ready"} = json_response(resp, 200)
  end
end
