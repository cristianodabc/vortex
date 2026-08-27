defmodule Vortex.F1.Live.ReplayTimelineTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Driver
  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.Session

  test "sorts events, filters unknown topics, and enforces the event bound" do
    timeline =
      ReplayTimeline.new(
        session(),
        :fixture,
        [
          event(3, :position, 3_000, %{position: 1}),
          event(1, :unknown, 1_000, %{}),
          event(2, :driver, 2_000, %{driver: driver()})
        ],
        max_events: 1
      )

    assert timeline.event_count == 1
    assert timeline.truncated?
    assert [%Event{id: 2}] = timeline.events
    assert timeline.duration_ms == 0
  end

  test "projects a cursor without retaining intermediate snapshots" do
    timeline =
      ReplayTimeline.new(
        session(),
        :fixture,
        [
          event(1, :driver, 1_000, %{driver: driver(), team_colour: "3671C6"}),
          event(2, :position, 2_500, %{position: 4}),
          event(3, :position, 4_000, %{position: 2})
        ]
      )

    projection = ReplayTimeline.project(timeline, 2)

    assert projection.status == :replay
    assert projection.source == :fixture

    assert projection.rows |> hd() |> Map.take([:position, :team_colour]) == %{
             position: 4,
             team_colour: "3671C6"
           }

    assert ReplayTimeline.delay_after(timeline, 1) == 1_500
    assert ReplayTimeline.delay_after(timeline, 3) == nil
  end

  test "invalid event-limit options cannot select an unbounded tail" do
    timeline =
      ReplayTimeline.new(
        session(),
        :fixture,
        [event(1, :position, 1_000, %{position: 1})],
        max_events: -1
      )

    assert timeline.event_count == 1
    refute timeline.truncated?
  end

  defp session do
    %Session{id: "session-101", key: 101, kind: :race, name: "Replay Grand Prix"}
  end

  defp driver do
    %Driver{ref: "driver-1", display_name: "Driver 1", team_colour: "3671C6"}
  end

  defp event(id, topic, offset_ms, changes) do
    %Event{
      id: id,
      session_key: 101,
      topic: topic,
      key: "driver-1",
      occurred_at: DateTime.add(~U[2026-01-01 12:00:00Z], offset_ms, :millisecond),
      changes: changes
    }
  end
end
