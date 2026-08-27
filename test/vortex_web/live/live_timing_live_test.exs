defmodule VortexWeb.LiveTimingLiveTest do
  use VortexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vortex.F1.Driver
  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.RaceState
  alias Vortex.F1.Live.ReplayStore
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow

  setup do
    original = Application.fetch_env!(:vortex, :f1)
    topic = "vortex:test:live-timing:#{System.unique_integer([:positive])}"

    server =
      start_supervised!(
        Supervisor.child_spec(
          {RaceState, name: nil, topic: topic, observer: self()},
          id: {RaceState, topic}
        )
      )

    replay_store =
      start_supervised!(
        Supervisor.child_spec(
          {ReplayStore, name: nil, task_supervisor: Vortex.F1.TaskSupervisor},
          id: {ReplayStore, topic}
        )
      )

    timeline = replay_timeline()
    Application.put_env(:vortex, :replay_fixture, %{owner: self(), timeline: timeline})

    configured =
      original
      |> Keyword.put(:race_state_server, server)
      |> Keyword.put(:current_race_topic, topic)
      |> Keyword.put(:replay_provider, Vortex.F1.ReplayFixtureProvider)
      |> Keyword.put(:replay_store_server, replay_store)

    Application.put_env(:vortex, :f1, configured)

    on_exit(fn ->
      Application.put_env(:vortex, :f1, original)
      Application.delete_env(:vortex, :replay_fixture)
    end)

    %{server: server, topic: topic, timeline: timeline}
  end

  test "disconnected render does not cause a second current-state read", context do
    seed_live_projection(context.server)

    {:ok, view, _html} = live(context.conn, "/live-timing")

    assert_receive {:vortex_race_state, :current_read}
    refute_receive {:vortex_race_state, :current_read}
    assert has_element?(view, "#live-timing-state[data-state=live]", "Live")
  end

  test "connected startup reads one coherent projection into stable timing rows", context do
    seed_live_projection(context.server)

    {:ok, view, _html} = live(context.conn, "/live-timing")
    assert_receive {:vortex_race_state, :current_read}

    assert has_element?(view, "#live-timing-state[data-state=live]", "Live")
    assert has_element?(view, "#timing-rows[phx-update=stream]")
    assert has_element?(view, "#timing-row-driver-1", "Driver 1")
    assert has_element?(view, ~s|#timing-row-driver-1 [data-team-colour="3671C6"]|)
  end

  test "newer notifications converge, reorder the stream, and equal versions are ignored",
       context do
    seed_live_projection(context.server)
    add_driver(context.server, 2, 2, 3)

    {:ok, view, _html} = live(context.conn, "/live-timing")
    assert_receive {:vortex_race_state, :current_read}
    html = render(view)
    assert before?(html, "timing-row-driver-1", "timing-row-driver-2")

    {:ok, projection} = RaceState.current(context.server)
    assert_receive {:vortex_race_state, :current_read}

    send(
      view.pid,
      {Vortex.F1, :current_race_updated, projection.generation, projection.sequence}
    )

    refute_receive {:vortex_race_state, :current_read}

    events = [
      event(5, :position, "driver-1", %{position: 2}),
      event(6, :position, "driver-2", %{position: 1})
    ]

    RaceState.apply_batch(context.server, events, later())
    assert_receive {:vortex_race_state, :current_read}

    html = render(view)
    assert before?(html, "timing-row-driver-2", "timing-row-driver-1")
  end

  test "multiple viewers share one state owner and perform no provider connection work",
       context do
    seed_live_projection(context.server)
    state_pid = context.server

    {:ok, first, _html} = live(context.conn, "/live-timing")
    assert_receive {:vortex_race_state, :current_read}

    {:ok, second, _html} = live(recycle(context.conn), "/live-timing")
    assert_receive {:vortex_race_state, :current_read}

    assert Process.alive?(state_pid)
    assert has_element?(first, "#timing-row-driver-1")
    assert has_element?(second, "#timing-row-driver-1")
    refute_receive {:provider_connection_started, _viewer}
  end

  test "renders every timing lifecycle state honestly", context do
    states = %{
      inactive: "No active session",
      connecting: "Connecting",
      live: "Live",
      stale: "Delayed",
      rate_limited: "Rate limited",
      reconnecting: "Reconnecting",
      resyncing: "Resynchronizing",
      degraded: "Last-known",
      replay: "Replay",
      unavailable: "Unavailable"
    }

    for {status, label} <- states do
      projection = %RaceProjection{
        session_key: 101,
        session: session(),
        source: :fixture,
        status: status,
        rows: [%TimingRow{id: "timing-row-driver-1", position: 1, driver: driver(1)}]
      }

      RaceState.reconcile(context.server, projection, now())
      {:ok, view, _html} = live(recycle(context.conn), "/live-timing")
      assert has_element?(view, "#live-timing-state[data-state=#{status}]", label)
    end
  end

  test "replay startup is URL-owned and isolated from current race state", context do
    seed_live_projection(context.server)

    {:ok, view, _html} =
      live(context.conn, "/live-timing?mode=replay&season=2026&session=101")

    render_async(view)

    assert_receive {:replay_fixture, :sessions, 2026}
    assert_receive {:replay_fixture, :timeline, 101}
    refute_receive {:vortex_race_state, :current_read}

    assert has_element?(view, "#live-timing-state[data-state=replay]", "Replay")
    assert has_element?(view, "#replay-controls")
    assert has_element?(view, "#replay-progress", "0 / 3 events")

    assert {:ok, projection} = RaceState.current(context.server)
    assert projection.status == :live
  end

  test "replay controls step, scrub, restart, speed, and reject stale timer generations",
       context do
    {:ok, view, _html} =
      live(context.conn, "/live-timing?mode=replay&season=2026&session=101")

    render_async(view)

    view |> element("#replay-step") |> render_click()
    assert has_element?(view, "#timing-row-driver-1", "Driver 1")
    assert has_element?(view, "#replay-progress", "1 / 3 events")

    view |> element("#replay-scrubber") |> render_change(%{"cursor" => "3"})
    assert has_element?(view, "#timing-row-driver-1", "Driver 1")
    assert has_element?(view, "#replay-progress", "3 / 3 events")

    view |> element("#replay-restart") |> render_click()
    assert has_element?(view, "#replay-progress", "0 / 3 events")

    view |> element("#replay-speed") |> render_change(%{"speed" => "2"})
    assert has_element?(view, ~s|#replay-speed option[selected][value="2"]|)

    view |> element("#replay-toggle") |> render_click()
    active_generation = live_assign(view, :timer_generation)
    send(view.pid, {:replay_tick, active_generation})
    assert has_element?(view, "#replay-progress", "1 / 3 events")

    view |> element("#replay-toggle") |> render_click()
    send(view.pid, {:replay_tick, active_generation})
    assert has_element?(view, "#replay-progress", "1 / 3 events")
  end

  test "multiple replay viewers share one bounded provider load but own independent cursors",
       context do
    path = "/live-timing?mode=replay&season=2026&session=101"
    {:ok, first, _html} = live(context.conn, path)
    render_async(first)
    assert_receive {:replay_fixture, :timeline, 101}

    {:ok, second, _html} = live(recycle(context.conn), path)
    render_async(second)
    refute_receive {:replay_fixture, :timeline, 101}

    first |> element("#replay-step") |> render_click()
    assert has_element?(first, "#replay-progress", "1 / 3 events")
    assert has_element?(second, "#replay-progress", "0 / 3 events")
  end

  test "canonicalizes a replay session outside the selected season", context do
    {:ok, view, _html} =
      live(context.conn, "/live-timing?mode=replay&season=2026&session=999")

    render_async(view)

    assert_patch(view, "/live-timing?mode=replay&season=2026")
    refute_receive {:replay_fixture, :timeline, 999}
    assert has_element?(view, "#live-timing-state[data-state=replay]", "Select a past race")
  end

  defp seed_live_projection(server) do
    RaceState.begin_session(server, session(), :fixture, now())
    add_driver(server, 1, 1, 1)
    RaceState.transition(server, :live, later())
  end

  defp add_driver(server, number, position, event_id) do
    events = [
      event(event_id, :driver, "driver-#{number}", %{
        driver: driver(number),
        team_colour: "3671C6"
      }),
      event(event_id + 1, :position, "driver-#{number}", %{position: position})
    ]

    RaceState.apply_batch(server, events, now())
  end

  defp session do
    %Session{id: "session-101", key: 101, kind: :race, name: "Grand Prix"}
  end

  defp driver(number) do
    %Driver{
      ref: "driver-#{number}",
      number: number,
      code: "D#{number}",
      display_name: "Driver #{number}",
      team_name: "Team",
      team_colour: "3671C6"
    }
  end

  defp event(id, topic, key, changes) do
    %Event{
      id: id,
      session_key: 101,
      topic: topic,
      key: key,
      occurred_at: now(),
      changes: changes
    }
  end

  defp replay_timeline do
    events = [
      event(1, :driver, "driver-1", %{
        driver: driver(1),
        team_colour: "3671C6"
      }),
      event(2, :position, "driver-1", %{position: 1}),
      event(3, :interval, "driver-1", %{gap: "Leader", interval: "—"})
    ]

    ReplayTimeline.new(session(), :fixture, events)
  end

  defp now do
    ~U[2026-08-27 12:00:00Z]
  end

  defp later do
    ~U[2026-08-27 12:00:01Z]
  end

  defp before?(html, first, second) do
    {first_position, _length} = :binary.match(html, first)
    {second_position, _length} = :binary.match(html, second)
    first_position < second_position
  end

  defp live_assign(view, key) do
    state = :sys.get_state(view.pid)
    Map.fetch!(state.socket.assigns, key)
  end
end

defmodule Vortex.F1.ReplayFixtureProvider do
  @moduledoc false

  alias Vortex.F1.Session

  def sessions(season) do
    fixture = Application.fetch_env!(:vortex, :replay_fixture)
    send(fixture.owner, {:replay_fixture, :sessions, season})

    {:ok,
     [
       %Session{
         id: "session-101",
         key: 101,
         kind: :race,
         name: "Grand Prix",
         starts_at: ~U[2026-08-27 12:00:00Z],
         status: :replay
       }
     ]}
  end

  def timeline(session_key) do
    fixture = Application.fetch_env!(:vortex, :replay_fixture)
    send(fixture.owner, {:replay_fixture, :timeline, session_key})
    {:ok, fixture.timeline}
  end
end
