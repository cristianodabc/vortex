defmodule Vortex.F1.Live.RaceStateTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Driver
  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.RaceState
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow

  setup do
    topic = "vortex:test:race-state:#{System.unique_integer([:positive])}"
    server = start_supervised!({RaceState, name: nil, topic: topic})

    %{server: server, topic: topic}
  end

  test "commits coherent batches before broadcasting version-only notifications", context do
    subscribe(context.topic)
    assert {:error, :inactive} = RaceState.current(context.server)
    assert {:ok, {1, 0}} = RaceState.begin_session(context.server, session(101), :fixture, now())

    assert_receive {Vortex.F1, :current_race_updated, 1, 0}
    assert {:ok, %RaceProjection{generation: 1, sequence: 0}} = RaceState.current(context.server)

    events = [
      event(2, :position, "driver-1", %{position: 1}),
      event(1, :driver, "driver-1", %{driver: driver(1), team_colour: "3671C6"})
    ]

    assert {:ok, {1, 1}, %{accepted: 2}} =
             RaceState.apply_batch(context.server, events, later())

    assert_receive {Vortex.F1, :current_race_updated, 1, 1}

    assert {:ok, %RaceProjection{} = committed} = RaceState.current(context.server)
    assert committed.captured_at == later()
    assert [%TimingRow{position: 1, team_colour: "3671C6"}] = committed.rows
  end

  test "does not publish redundant duplicate batches or repeated transitions", context do
    subscribe(context.topic)
    RaceState.begin_session(context.server, session(101), :fixture, now())
    assert_receive {Vortex.F1, :current_race_updated, 1, 0}

    update = event(1, :position, "driver-1", %{position: 1})
    assert {:ok, {1, 1}, %{accepted: 1}} = RaceState.apply_batch(context.server, [update], now())
    assert_receive {Vortex.F1, :current_race_updated, 1, 1}

    assert {:ok, {1, 1}, %{duplicate: 1}} =
             RaceState.apply_batch(context.server, [update], later())

    refute_receive {Vortex.F1, :current_race_updated, _, _}

    assert {:ok, {1, 2}} = RaceState.transition(context.server, :reconnecting, later())
    assert_receive {Vortex.F1, :current_race_updated, 1, 2}
    assert {:ok, {1, 2}} = RaceState.transition(context.server, :reconnecting, later())
    refute_receive {Vortex.F1, :current_race_updated, _, _}
  end

  test "enforces typed transitions and preserves last-known rows while stale", context do
    RaceState.begin_session(context.server, session(101), :fixture, now())

    RaceState.apply_batch(
      context.server,
      [event(1, :position, "driver-1", %{position: 1})],
      now()
    )

    assert {:ok, {1, 2}} = RaceState.transition(context.server, :live, later())

    stale_at = DateTime.add(later(), 10, :second)
    assert {:ok, {1, 3}} = RaceState.transition(context.server, :stale, stale_at)

    assert {:ok, %RaceProjection{} = stale} = RaceState.current(context.server)
    assert stale.status == :stale
    assert stale.stale_since == stale_at
    assert [%TimingRow{position: 1}] = stale.rows

    assert {:error, :invalid_transition} =
             RaceState.transition(context.server, :inactive, stale_at)

    assert {:ok, %RaceProjection{status: :stale, sequence: 3}} =
             RaceState.current(context.server)
  end

  test "reconciliation replaces atomically and a new generation retains no prior session",
       context do
    subscribe(context.topic)
    RaceState.begin_session(context.server, session(100), :fixture, now())
    assert_receive {Vortex.F1, :current_race_updated, 1, 0}

    RaceState.apply_batch(
      context.server,
      [event(1, :position, "old", %{position: 1}, 100)],
      now()
    )

    assert_receive {Vortex.F1, :current_race_updated, 1, 1}

    candidate = %RaceProjection{
      session_key: 100,
      session: session(100),
      source: :fixture,
      status: :live,
      rows: [%TimingRow{id: "timing-row-new", position: 2}],
      cursors: %{{:position, "new"} => 9}
    }

    assert {:ok, {1, 2}} = RaceState.reconcile(context.server, candidate, later())
    assert_receive {Vortex.F1, :current_race_updated, 1, 2}
    assert {:ok, %{rows: [%TimingRow{id: "timing-row-new"}]}} = RaceState.current(context.server)

    assert {:ok, {2, 0}} =
             RaceState.begin_session(context.server, session(101), :open_f1, later())

    assert_receive {Vortex.F1, :current_race_updated, 2, 0}

    assert {:ok, %RaceProjection{} = next} = RaceState.current(context.server)
    assert next.session_key == 101
    assert next.rows == []
    assert next.cursors == %{}
  end

  test "a caller repairs a missed PubSub notification by rereading canonical state", context do
    RaceState.begin_session(context.server, session(101), :fixture, now())

    RaceState.apply_batch(
      context.server,
      [event(1, :position, "driver-1", %{position: 1})],
      now()
    )

    subscribe(context.topic)

    assert {:ok, %RaceProjection{generation: 1, sequence: 1}} =
             RaceState.current(context.server)

    assert {:ok, {1, 2}} = RaceState.transition(context.server, :live, later())
    assert_receive {Vortex.F1, :current_race_updated, 1, 2}
  end

  defp subscribe(topic) do
    Phoenix.PubSub.subscribe(Vortex.PubSub, topic)
  end

  defp session(key) do
    %Session{id: "session-#{key}", key: key, kind: :race, name: "Race"}
  end

  defp event(id, topic, key, changes, session_key \\ 101) do
    %Event{
      id: id,
      session_key: session_key,
      topic: topic,
      key: key,
      occurred_at: now(),
      changes: changes
    }
  end

  defp driver(number) do
    %Driver{
      ref: "driver-#{number}",
      number: number,
      code: "D#{number}",
      display_name: "Driver #{number}",
      team_colour: "3671C6"
    }
  end

  defp now do
    ~U[2026-08-27 12:00:00Z]
  end

  defp later do
    ~U[2026-08-27 12:00:01Z]
  end
end
