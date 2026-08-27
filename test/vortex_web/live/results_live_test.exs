defmodule VortexWeb.ResultsLiveTest do
  use VortexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vortex.F1.Cache.Server
  alias Vortex.F1.Constructor
  alias Vortex.F1.Driver
  alias Vortex.F1.Error
  alias Vortex.F1.FakeReferenceProvider
  alias Vortex.F1.Meeting
  alias Vortex.F1.Result
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
         max_entries: 16}
      )

    configured =
      original
      |> Keyword.put(:reference_provider, FakeReferenceProvider)
      |> Keyword.put(:reference_source, :fixture)
      |> Keyword.put(:reference_cache_server, cache)
      |> Keyword.put(:current_results_ttl_ms, 1_000)

    Application.put_env(:vortex, :f1, configured)

    on_exit(fn -> Application.put_env(:vortex, :f1, original) end)

    %{clock: clock, current_season: Date.utc_today().year}
  end

  test "resolves the latest completed race before loading default results", %{
    conn: conn,
    current_season: season
  } do
    FakeReferenceProvider.put(
      {:schedule, season},
      {:ok, [meeting(season, 1, "Opening Grand Prix"), meeting(season, 2, "Latest Grand Prix")]}
    )

    FakeReferenceProvider.put(
      {:results, season, 2, :race},
      {:ok, [result(2, "norris", 0.0), result(1, "verstappen", 25.0, "1:31.000")]}
    )

    {:ok, view, _html} = live(conn, "/results")
    assert_patch(view, "/results?round=2&season=#{season}&session=race")
    html = render_async(view)

    assert has_element?(view, "#results-state[data-state=success]")
    assert has_element?(view, "#result-rows[phx-update=stream]")
    assert has_element?(view, "#result-row-driver-verstappen")
    assert has_element?(view, "#result-row-driver-norris", "0")
    assert has_element?(view, "#result-row-driver-verstappen", "Fastest lap")
    assert has_element?(view, ~s|#results-round option[value="2"][selected]|, "Latest Grand Prix")
    assert before?(html, "result-row-driver-verstappen", "result-row-driver-norris")
  end

  test "session tabs patch canonical explicit filters", %{conn: conn} do
    FakeReferenceProvider.put({:results, 2024, 2, :race}, {:ok, [result(1, "driver", 10.0)]})
    FakeReferenceProvider.put({:results, 2024, 2, :qualifying}, {:ok, []})

    {:ok, view, _html} = live(conn, "/results?season=2024&round=2&session=race")
    render_async(view)

    view |> element("#results-session-qualifying") |> render_click()
    assert_patch(view, "/results?round=2&season=2024&session=qualifying")
    render_async(view)
    assert has_element?(view, "#results-state[data-state=empty]")
  end

  test "uses the selected season calendar as the bounded race selector", %{conn: conn} do
    meetings = [
      meeting(2024, 1, "Bahrain Grand Prix"),
      meeting(2024, 2, "Saudi Arabian Grand Prix")
    ]

    FakeReferenceProvider.put({:schedule, 2024}, {:ok, meetings})
    FakeReferenceProvider.put({:results, 2024, 1, :race}, {:ok, []})
    FakeReferenceProvider.put({:results, 2024, 2, :race}, {:ok, []})

    {:ok, view, _html} = live(conn, "/results?season=2024&round=1&session=race")
    render_async(view)

    assert has_element?(view, ~s|#results-round option[value="1"]|, "Bahrain Grand Prix")
    assert has_element?(view, ~s|#results-round option[value="2"]|, "Saudi Arabian Grand Prix")
    refute has_element?(view, ~s|#results-round option[value="3"]|)

    view
    |> form("#results-filters", %{"season" => "2024", "round" => "2"})
    |> render_change()

    assert_patch(view, "/results?round=2&season=2024&session=race")
  end

  test "renders normalized missing values as neutral dashes", %{conn: conn} do
    missing = %Result{id: "result-missing", position: 1, driver: driver("missing")}
    FakeReferenceProvider.put({:results, 2024, 1, :race}, {:ok, [missing]})

    {:ok, view, _html} = live(conn, "/results?season=2024&round=1&session=race")
    render_async(view)

    assert has_element?(view, "#result-row-driver-missing", "—")
  end

  test "renders labeled qualifying phase times", %{conn: conn} do
    qualifying = %Result{
      id: "qualifying-driver",
      position: 1,
      driver: driver("qualifier"),
      q1: "1:30.031",
      q2: "1:29.374",
      q3: "1:29.179",
      time: "1:29.179"
    }

    FakeReferenceProvider.put({:results, 2024, 1, :qualifying}, {:ok, [qualifying]})

    {:ok, view, _html} =
      live(conn, "/results?season=2024&round=1&session=qualifying")

    render_async(view)

    assert has_element?(view, "#result-row-driver-qualifier .qualifying-splits", "Q1 1:30.031")
    assert has_element?(view, "#result-row-driver-qualifier .qualifying-splits", "Q2 1:29.374")
    assert has_element?(view, "#result-row-driver-qualifier .qualifying-splits", "Q3 1:29.179")
  end

  test "renders stale last-known results and sanitized failures", %{
    conn: conn,
    clock: clock,
    current_season: season
  } do
    FakeReferenceProvider.put({:results, season, 1, :race}, {:ok, [result(1, "old", 1.0)]})
    assert {:ok, _resource} = Vortex.F1.results(season, 1, :race)
    Agent.update(clock, &DateTime.add(&1, 1_001, :millisecond))

    FakeReferenceProvider.put(
      {:results, season, 1, :race},
      {:error, Error.new(:upstream, provider_body: "private body")}
    )

    {:ok, view, _html} = live(conn, "/results")
    html = render_async(view)
    assert has_element?(view, "#results-state[data-state=stale]")
    assert has_element?(view, "#result-row-driver-old")
    refute html =~ "private body"
  end

  test "distinguishes rate limits from unavailable data", %{conn: conn} do
    FakeReferenceProvider.put(
      {:results, 2098, 1, :race},
      {:error, Error.new(:rate_limited, retry_after_ms: 2_000)}
    )

    {:ok, rate_limited, _html} =
      live(conn, "/results?season=2098&round=1&session=race")

    render_async(rate_limited)
    assert has_element?(rate_limited, "#results-state[data-state=rate_limited]")

    FakeReferenceProvider.put(
      {:results, 2099, 1, :race},
      {:error, Error.new(:unavailable)}
    )

    {:ok, unavailable, _html} =
      live(recycle(conn), "/results?season=2099&round=1&session=race")

    render_async(unavailable)
    assert has_element?(unavailable, "#results-state[data-state=unavailable]")
  end

  defp result(position, ref, points, fastest_lap \\ nil) do
    %Result{
      id: "result-#{ref}",
      position: position,
      driver: driver(ref),
      constructor: %Constructor{ref: "constructor-test", name: "Test Team"},
      grid: position,
      laps: 57,
      time: if(position == 1, do: "1:30:00", else: "+5.000"),
      status: "Finished",
      points: points,
      fastest_lap: fastest_lap
    }
  end

  defp driver(ref) do
    %Driver{
      ref: "driver-#{ref}",
      code: ref |> String.slice(0, 3) |> String.upcase(),
      display_name: String.capitalize(ref)
    }
  end

  defp meeting(season, round, name) do
    starts_at = DateTime.add(~U[2024-01-01 12:00:00Z], round, :day)

    %Meeting{
      id: "meeting-#{season}-#{round}",
      season: season,
      round: round,
      name: name,
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

  defp before?(html, first, second) do
    {first_position, _length} = :binary.match(html, first)
    {second_position, _length} = :binary.match(html, second)
    first_position < second_position
  end
end
