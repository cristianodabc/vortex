defmodule VortexWeb.ScheduleLiveTest do
  use VortexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vortex.F1.Cache.Server
  alias Vortex.F1.Error
  alias Vortex.F1.FakeReferenceProvider
  alias Vortex.F1.Meeting
  alias Vortex.F1.Session

  setup do
    original = Application.fetch_env!(:vortex, :f1)
    clock = start_supervised!({Agent, fn -> ~U[2026-08-27 12:00:00Z] end})
    task_supervisor = start_supervised!({Task.Supervisor, []})
    start_supervised!({FakeReferenceProvider, %{}})

    cache =
      start_supervised!(
        {Server,
         name: nil,
         clock: fn -> Agent.get(clock, & &1) end,
         task_supervisor: task_supervisor,
         observer: self(),
         max_entries: 16,
         failure_retry_ms: 1_000}
      )

    configured =
      original
      |> Keyword.put(:reference_provider, FakeReferenceProvider)
      |> Keyword.put(:reference_source, :fixture)
      |> Keyword.put(:reference_cache_server, cache)
      |> Keyword.put(:schedule_ttl_ms, 1_000)

    Application.put_env(:vortex, :f1, configured)

    on_exit(fn ->
      Application.put_env(:vortex, :f1, original)
    end)

    %{clock: clock, current_season: Date.utc_today().year}
  end

  test "loads the current schedule into stable calendar events and selected details", %{
    conn: conn,
    current_season: season
  } do
    parent = self()

    FakeReferenceProvider.put({:schedule, season}, fn ->
      send(parent, {:initial_load_started, self()})

      receive do
        :release -> {:ok, [meeting(season, 2), meeting(season, 1)]}
      end
    end)

    {:ok, view, _html} = live(conn, "/schedule")
    assert has_element?(view, "#schedule-state[data-state=loading][aria-busy=true]")
    assert_receive {:initial_load_started, loader_pid}
    send(loader_pid, :release)

    render_async(view)

    assert has_element?(view, "#schedule-state[data-state=success][aria-busy=false]")
    assert has_element?(view, "#schedule-calendar[role=grid]")
    assert has_element?(view, "#schedule-event-round-1[data-status=completed]")
    assert has_element?(view, "#schedule-event-round-2[data-status=completed][aria-current=page]")
    assert has_element?(view, "#schedule-detail-round-2")
    assert has_element?(view, "#schedule-session-2-race")
    assert has_element?(view, "#schedule-freshness", "Fresh")
  end

  test "renders a semantic month calendar and patches race details on date selection", %{
    conn: conn,
    current_season: season
  } do
    FakeReferenceProvider.put(
      {:schedule, season},
      {:ok, [meeting(season, 1), meeting(season, 2)]}
    )

    {:ok, view, _html} =
      live(conn, "/schedule?season=#{season}&month=1&round=1")

    render_async(view)

    assert has_element?(view, "#schedule-calendar[role=grid]")
    assert has_element?(view, ~s|#schedule-weekdays [role=columnheader][aria-label="Monday"]|)

    assert has_element?(
             view,
             ~s|#schedule-current-month[href="/schedule?month=#{Date.utc_today().month}&season=#{Date.utc_today().year}"]|
           )

    assert has_element?(view, "#schedule-day-#{season}-01-02[role=gridcell]")
    assert has_element?(view, "#schedule-event-round-1[aria-current=page]")
    assert has_element?(view, "#schedule-detail-round-1", "Circuit 1")

    view
    |> element("#schedule-event-round-2")
    |> render_click()

    assert_patch(view, "/schedule?month=1&round=2&season=#{season}")
    render_async(view)
    assert has_element?(view, "#schedule-detail-round-2", "Circuit 2")
  end

  test "distinguishes completed, in-progress, and upcoming weekends", %{
    conn: conn,
    current_season: season
  } do
    now = DateTime.utc_now()

    completed = meeting_at(season, 1, "Completed Grand Prix", DateTime.add(now, -1, :day))
    active = meeting_at(season, 2, "Active Grand Prix", DateTime.add(now, -1, :minute))
    upcoming = meeting_at(season, 3, "Upcoming Grand Prix", DateTime.add(now, 1, :day))

    FakeReferenceProvider.put({:schedule, season}, {:ok, [completed, active, upcoming]})

    {:ok, view, _html} = live(conn, "/schedule")
    render_async(view)

    assert has_element?(view, "#schedule-event-round-1[data-status=completed]")
    assert has_element?(view, "#schedule-event-round-2[data-status=in_progress]")
    assert has_element?(view, "#schedule-event-round-3[data-status=upcoming]")
  end

  test "patches between current and historical seasons", %{
    conn: conn,
    current_season: current_season
  } do
    FakeReferenceProvider.put({:schedule, current_season}, {:ok, []})
    FakeReferenceProvider.put({:schedule, 2024}, {:ok, [meeting(2024, 1)]})

    {:ok, view, _html} = live(conn, "/schedule")
    render_async(view)

    view
    |> form("#schedule-filters", %{"season" => "2024"})
    |> render_change()

    assert_patch(view, "/schedule?season=2024")
    render_async(view)

    assert has_element?(view, ~s|#schedule-season option[value="2024"][selected]|)
    assert has_element?(view, "#schedule-round-1")
  end

  test "renders a distinct empty state", %{conn: conn, current_season: season} do
    FakeReferenceProvider.put({:schedule, season}, {:ok, []})

    {:ok, view, _html} = live(conn, "/schedule")
    render_async(view)

    assert has_element?(view, "#schedule-state[data-state=empty]")
    assert has_element?(view, "#schedule-empty", "No races are available")
  end

  test "renders rate-limited and unavailable failures without provider details", %{
    conn: conn,
    current_season: season
  } do
    secret = "raw provider body"

    FakeReferenceProvider.put(
      {:schedule, season},
      {:error,
       Error.new(:rate_limited,
         source: :fixture,
         retry_after_ms: 2_000,
         provider_body: secret
       )}
    )

    {:ok, rate_limited, _html} = live(conn, "/schedule")
    html = render_async(rate_limited)
    assert has_element?(rate_limited, "#schedule-state[data-state=rate_limited]")
    refute html =~ secret

    other_season = season + 1

    FakeReferenceProvider.put(
      {:schedule, other_season},
      {:error, Error.new(:unavailable, provider_body: secret)}
    )

    {:ok, unavailable, _html} = live(recycle(conn), "/schedule?season=#{other_season}")
    html = render_async(unavailable)
    assert has_element?(unavailable, "#schedule-state[data-state=unavailable]")
    refute html =~ secret
  end

  test "serves stale rows immediately and converges after a refresh notification", %{
    conn: conn,
    clock: clock,
    current_season: season
  } do
    old_meeting = meeting(season, 1, "Old Grand Prix")
    new_meeting = meeting(season, 1, "Updated Grand Prix")
    FakeReferenceProvider.put({:schedule, season}, {:ok, [old_meeting]})
    assert {:ok, _resource} = Vortex.F1.schedule(season)
    advance(clock, 1_001)

    parent = self()

    FakeReferenceProvider.put({:schedule, season}, fn ->
      send(parent, {:refresh_started, self()})

      receive do
        :release -> {:ok, [new_meeting]}
      end
    end)

    {:ok, view, _html} = live(conn, "/schedule")
    render_async(view)

    assert has_element?(view, "#schedule-state[data-state=stale]")
    assert has_element?(view, "#schedule-round-1", "Old Grand Prix")
    assert_receive {:refresh_started, refresh_pid}

    send(refresh_pid, :release)
    assert_receive {:vortex_cache, :refresh_completed, {:schedule, ^season}}
    render_async(view)

    assert has_element?(view, "#schedule-state[data-state=success]")
    assert has_element?(view, "#schedule-round-1", "Updated Grand Prix")
  end

  test "labels last-known data degraded after a failed refresh", %{
    conn: conn,
    clock: clock,
    current_season: season
  } do
    FakeReferenceProvider.put({:schedule, season}, {:ok, [meeting(season, 1)]})
    assert {:ok, _resource} = Vortex.F1.schedule(season)
    advance(clock, 1_001)

    FakeReferenceProvider.put(
      {:schedule, season},
      {:error, Error.new(:upstream, source: :fixture)}
    )

    assert {:ok, _stale_resource} = Vortex.F1.schedule(season)
    assert_receive {:vortex_cache, :refresh_failed, {:schedule, ^season}}

    {:ok, view, _html} = live(conn, "/schedule")
    render_async(view)

    assert has_element?(view, "#schedule-state[data-state=degraded]")
    assert has_element?(view, "#schedule-round-1")
  end

  defp meeting(season, round, name \\ nil) do
    starts_at =
      season
      |> Date.new!(1, min(round + 1, 28))
      |> DateTime.new!(~T[12:00:00])

    meeting_at(
      season,
      round,
      name || "Round #{round} Grand Prix",
      starts_at
    )
  end

  defp meeting_at(season, round, name, starts_at) do
    %Meeting{
      id: "meeting-#{season}-#{round}",
      season: season,
      round: round,
      name: name,
      circuit_name: "Circuit #{round}",
      locality: "City #{round}",
      country: "Country #{round}",
      starts_at: starts_at,
      sessions: [
        %Session{
          id: "session-#{season}-#{round}-race",
          kind: :race,
          name: "Race",
          starts_at: starts_at
        }
      ]
    }
  end

  defp advance(clock, milliseconds) do
    Agent.update(clock, &DateTime.add(&1, milliseconds, :millisecond))
  end
end
