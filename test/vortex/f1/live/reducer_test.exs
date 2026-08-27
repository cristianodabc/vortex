defmodule Vortex.F1.Live.ReducerTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.Reducer
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow

  describe "apply_batch/3" do
    test "keeps the greatest event id per topic and key regardless of delivery order" do
      projection = projection(101)

      events = [
        event(3, :position, "driver-1", %{position: 1}),
        event(2, :position, "driver-1", %{position: 2})
      ]

      assert {updated, summary} = Reducer.apply_batch(projection, events, now())
      assert [%TimingRow{position: 1}] = updated.rows
      assert updated.cursors[{:position, "driver-1"}] == 3
      assert updated.sequence == 1
      assert summary.accepted == 1
      assert summary.coalesced == 1

      assert {duplicate, duplicate_summary} =
               Reducer.apply_batch(
                 updated,
                 [event(3, :position, "driver-1", %{position: 9})],
                 now()
               )

      assert duplicate == updated
      assert duplicate_summary.duplicate == 1

      assert {older, older_summary} =
               Reducer.apply_batch(
                 updated,
                 [event(1, :position, "driver-1", %{position: 9})],
                 now()
               )

      assert older == updated
      assert older_summary.older == 1
    end

    test "tracks cursors independently per topic and logical key" do
      events = [
        event(8, :position, "driver-1", %{position: 2}),
        event(1, :interval, "driver-1", %{gap: "+1.200", interval: "+0.400"}),
        event(4, :position, "driver-2", %{position: 1})
      ]

      assert {updated, %{accepted: 3}} = Reducer.apply_batch(projection(101), events, now())
      assert updated.cursors[{:position, "driver-1"}] == 8
      assert updated.cursors[{:interval, "driver-1"}] == 1
      assert updated.cursors[{:position, "driver-2"}] == 4

      assert Enum.map(updated.rows, & &1.id) == ["timing-row-driver-2", "timing-row-driver-1"]
      assert Enum.at(updated.rows, 1).gap == "+1.200"
    end

    test "rejects malformed, unknown, and wrong-session events without creating atoms or rows" do
      events = [
        %Event{id: nil, session_key: 101, topic: :position, key: "driver-1"},
        %Event{id: 1, session_key: 101, topic: :unknown, key: "driver-1", changes: %{}},
        event(1, :position, "driver-1", %{unsupported: "value"}),
        %{raw_provider: "payload"},
        %{event(1, :position, "driver-1", %{position: 1}) | session_key: 999}
      ]

      assert {unchanged, summary} = Reducer.apply_batch(projection(101), events, now())
      assert unchanged.rows == []
      assert unchanged.sequence == 0
      assert summary.malformed == 4
      assert summary.unknown == 1
    end

    test "orders ties stably and bounds the projection to current grid size" do
      events =
        for number <- 25..1//-1 do
          event(number, :position, "driver-#{number}", %{
            position: if(number in [1, 2], do: 1, else: number)
          })
        end

      assert {updated, _summary} = Reducer.apply_batch(projection(101), events, now())
      assert length(updated.rows) == 22

      assert Enum.take(Enum.map(updated.rows, & &1.id), 2) == [
               "timing-row-driver-1",
               "timing-row-driver-2"
             ]

      refute Enum.any?(updated.rows, &(&1.id == "timing-row-driver-25"))
    end
  end

  describe "session and reconciliation boundaries" do
    test "begin_session/4 increments generation and clears every prior-session value" do
      prior = %RaceProjection{
        projection(100)
        | generation: 7,
          sequence: 12,
          rows: [%TimingRow{id: "timing-row-old", position: 1}],
          cursors: %{{:position, "old"} => 50},
          status: :live
      }

      session = %Session{id: "session-101", key: 101, kind: :race, name: "Race"}
      next = Reducer.begin_session(prior, session, :open_f1, now())

      assert next.session_key == 101
      assert next.session == session
      assert next.generation == 8
      assert next.sequence == 0
      assert next.status == :connecting
      assert next.source == :open_f1
      assert next.rows == []
      assert next.cursors == %{}
    end

    test "reconcile/3 atomically replaces same-session rows and advances one version" do
      current = %RaceProjection{
        projection(101)
        | generation: 3,
          sequence: 9,
          rows: [%TimingRow{id: "timing-row-old", position: 1}],
          cursors: %{{:position, "old"} => 4},
          status: :resyncing
      }

      candidate = %RaceProjection{
        projection(101)
        | rows: [
            %TimingRow{id: "timing-row-driver-2", position: 2},
            %TimingRow{id: "timing-row-driver-1", position: 1}
          ],
          cursors: %{{:position, "driver-1"} => 10},
          status: :live
      }

      replaced = Reducer.reconcile(current, candidate, now())

      assert replaced.generation == 3
      assert replaced.sequence == 10
      assert replaced.status == :live
      assert replaced.captured_at == now()

      assert Enum.map(replaced.rows, & &1.id) == [
               "timing-row-driver-1",
               "timing-row-driver-2"
             ]

      refute Enum.any?(replaced.rows, &(&1.id == "timing-row-old"))
    end
  end

  defp projection(session_key) do
    %RaceProjection{
      session_key: session_key,
      session: %Session{id: "session-#{session_key}", key: session_key, kind: :race, name: "Race"},
      source: :fixture
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

  defp now do
    ~U[2026-08-27 12:00:00Z]
  end
end
