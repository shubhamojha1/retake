defmodule RetakeWeb.HealthControllerTest do
  use RetakeWeb.ConnCase, async: true

  test "GET /api/health reports ok and reaches the database", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
