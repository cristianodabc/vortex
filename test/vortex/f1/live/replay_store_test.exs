defmodule Vortex.F1.Live.ReplayStoreTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.ReplayStore
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.Session

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})
    task_supervisor = start_supervised!({Task.Supervisor, name: nil})

    store =
      start_supervised!(
        Supervisor.child_spec(
          {ReplayStore,
           name: nil,
           clock: fn -> Agent.get(clock, & &1) end,
           task_supervisor: task_supervisor,
           ttl_ms: 1_000,
           max_timelines: 2,
           max_events: 2},
          id: {ReplayStore, System.unique_integer([:positive])}
        )
      )

    %{clock: clock, store: store}
  end

  test "coalesces concurrent timeline loads and shares one immutable value", context do
    parent = self()

    loader = fn ->
      send(parent, {:loader_started, self()})

      receive do
        :release_loader -> {:ok, timeline(101, 3)}
      end
    end

    first = Task.async(fn -> ReplayStore.open(context.store, 101, loader) end)
    assert_receive {:loader_started, loader_pid}
    second = Task.async(fn -> ReplayStore.open(context.store, 101, loader) end)
    send(loader_pid, :release_loader)

    assert {:ok, timeline} = Task.await(first)
    assert {:ok, ^timeline} = Task.await(second)
    assert timeline.event_count == 2
    assert timeline.truncated?
    refute_receive {:loader_started, _loader_pid}
  end

  test "expires old timelines and applies an LRU capacity bound", context do
    assert {:ok, _timeline} =
             ReplayStore.open(context.store, 101, fn -> {:ok, timeline(101, 1)} end)

    Agent.update(context.clock, fn _now -> 100 end)

    assert {:ok, _timeline} =
             ReplayStore.open(context.store, 102, fn -> {:ok, timeline(102, 1)} end)

    assert {:ok, _timeline} = ReplayStore.open(context.store, 101, fn -> flunk("cache miss") end)
    Agent.update(context.clock, fn _now -> 200 end)

    assert {:ok, _timeline} =
             ReplayStore.open(context.store, 103, fn -> {:ok, timeline(103, 1)} end)

    assert {:ok, _timeline} =
             ReplayStore.open(context.store, 102, fn -> {:ok, timeline(102, 1)} end)

    Agent.update(context.clock, fn _now -> 2_000 end)
    assert ReplayStore.evict_expired(context.store) == 2
  end

  defp timeline(session_key, count) do
    session = %Session{
      id: "session-#{session_key}",
      key: session_key,
      kind: :race,
      name: "Replay #{session_key}"
    }

    events =
      for id <- 1..count do
        %Event{
          id: id,
          session_key: session_key,
          topic: :position,
          key: "driver-#{id}",
          occurred_at: DateTime.add(~U[2026-01-01 12:00:00Z], id, :second),
          changes: %{position: id}
        }
      end

    ReplayTimeline.new(session, :fixture, events)
  end
end
