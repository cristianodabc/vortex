defmodule VortexWeb.StandingsLiveTest do
  use VortexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vortex.F1.Cache.Server
  alias Vortex.F1.Constructor
  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.Driver
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.FakeReferenceProvider

  setup do
    original = Application.fetch_env!(:vortex, :f1)
    task_supervisor = start_supervised!({Task.Supervisor, []})
    start_supervised!({FakeReferenceProvider, %{}})

    cache =
      start_supervised!({Server, name: nil, task_supervisor: task_supervisor, max_entries: 16})

    configured =
      original
      |> Keyword.put(:reference_provider, FakeReferenceProvider)
      |> Keyword.put(:reference_source, :fixture)
      |> Keyword.put(:reference_cache_server, cache)

    Application.put_env(:vortex, :f1, configured)
    on_exit(fn -> Application.put_env(:vortex, :f1, original) end)

    :ok
  end

  test "driver standings preserve ties, zero values, stable refs, and neutral team fallback", %{
    conn: conn
  } do
    standings = [
      %DriverStanding{
        id: "standing-driver-one",
        position: 1,
        driver: %Driver{ref: "driver-one", code: "ONE", display_name: "Driver One"},
        constructors: [%Constructor{ref: "constructor-one", name: "Team One"}],
        points: 0.0,
        wins: 0
      },
      %DriverStanding{
        id: "standing-driver-two",
        position: 1,
        driver: %Driver{ref: "driver-two", code: "TWO", display_name: "Driver Two"},
        constructors: [%Constructor{ref: "constructor-two", name: "Team Two"}],
        points: 0.0,
        wins: 0
      }
    ]

    FakeReferenceProvider.put({:driver_standings, 2024}, {:ok, standings})
    {:ok, view, _html} = live(conn, "/standings/drivers?season=2024")
    render_async(view)

    assert has_element?(view, "#driver-standings-state[data-state=success]")
    assert has_element?(view, "#driver-standing-rows[phx-update=stream]")
    assert has_element?(view, "#driver-standing-row-driver-one", "0")
    assert has_element?(view, "#driver-standing-row-driver-two")
    assert has_element?(view, ~s|#driver-standing-row-driver-one [data-team-colour="737373"]|)
  end

  test "constructor standings render stable references and nationality text", %{conn: conn} do
    standings = [
      %ConstructorStanding{
        id: "standing-constructor-one",
        position: 1,
        constructor: %Constructor{
          ref: "constructor-one",
          name: "Constructor One",
          nationality: "British",
          colour: "FF8700"
        },
        points: 100.0,
        wins: 2
      }
    ]

    FakeReferenceProvider.put({:constructor_standings, 2024}, {:ok, standings})
    {:ok, view, _html} = live(conn, "/standings/constructors?season=2024")
    render_async(view)

    assert has_element?(view, "#constructor-standings-state[data-state=success]")
    assert has_element?(view, "#constructor-standing-rows[phx-update=stream]")
    assert has_element?(view, "#constructor-standing-row-constructor-one", "British")

    assert has_element?(
             view,
             "#constructor-standing-row-constructor-one [data-team-colour=FF8700]"
           )
  end

  test "both routes patch current and historical seasons safely", %{conn: conn} do
    FakeReferenceProvider.put(:driver_standings, {:ok, []})
    FakeReferenceProvider.put(:constructor_standings, {:ok, []})

    {:ok, drivers, _html} = live(conn, "/standings/drivers")
    render_async(drivers)
    drivers |> form("#driver-standings-filters", %{"season" => "2024"}) |> render_change()
    assert_patch(drivers, "/standings/drivers?season=2024")

    {:ok, constructors, _html} = live(recycle(conn), "/standings/constructors")
    render_async(constructors)

    constructors
    |> form("#constructor-standings-filters", %{"season" => "2024"})
    |> render_change()

    assert_patch(constructors, "/standings/constructors?season=2024")
  end
end
