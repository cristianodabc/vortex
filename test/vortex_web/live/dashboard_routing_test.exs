defmodule VortexWeb.DashboardRoutingTest do
  use VortexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @routes [
    {"/live-timing", "live-timing-page", "nav-live-timing"},
    {"/schedule", "schedule-page", "nav-schedule"},
    {"/results", "results-page", "nav-results"},
    {"/standings/drivers", "driver-standings-page", "nav-driver-standings"},
    {"/standings/constructors", "constructor-standings-page", "nav-constructor-standings"}
  ]

  test "root redirects to the canonical live timing route", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn) == "/live-timing"
  end

  test "every dashboard route renders the shared full-page shell and active navigation", %{
    conn: conn
  } do
    for {path, page_id, active_nav_id} <- @routes do
      {:ok, view, _html} = live(recycle(conn), path)

      assert has_element?(view, "#vortex-dashboard")
      assert has_element?(view, "##{page_id}")
      assert has_element?(view, "##{active_nav_id}[aria-current=page]")

      for {_route, _page_id, nav_id} <- @routes, nav_id != active_nav_id do
        refute has_element?(view, "##{nav_id}[aria-current]")
      end

      assert has_element?(view, "#vortex-attribution")
      assert has_element?(view, "#attribution-jolpica[href]")
      assert has_element?(view, "#attribution-openf1[href]")
    end
  end

  test "invalid URL-owned filters patch to bounded canonical defaults", %{conn: conn} do
    current_season = Date.utc_today().year
    schedule_path = "/schedule?season=#{current_season}"
    results_path = "/results?round=1&season=#{current_season}&session=race"

    assert {:error, {:live_redirect, %{to: ^schedule_path}}} =
             live(conn, "/schedule?season=latest")

    assert {:error, {:live_redirect, %{to: ^results_path}}} =
             live(
               recycle(conn),
               "/results?season=1900&round=all&session=unknown"
             )
  end

  test "theme events accept only system, light, or dark", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/live-timing")
    assert has_element?(view, "#vortex-dashboard[data-theme-preference=system]")
    assert has_element?(view, ~s|#theme-system[aria-label="System theme"] .hero-computer-desktop|)
    assert has_element?(view, ~s|#theme-light[aria-label="Light theme"] .hero-sun|)
    assert has_element?(view, ~s|#theme-dark[aria-label="Dark theme"] .hero-moon|)

    render_hook(view, "theme_changed", %{"theme" => "neon"})
    assert has_element?(view, "#vortex-dashboard[data-theme-preference=system]")

    render_hook(view, "theme_changed", %{"theme" => "dark"})
    assert has_element?(view, "#vortex-dashboard[data-theme-preference=dark]")
  end
end
