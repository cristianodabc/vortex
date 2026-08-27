defmodule VortexWeb.PageControllerTest do
  use VortexWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/live-timing"
  end
end
