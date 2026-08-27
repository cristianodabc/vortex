defmodule Vortex.F1.Live.Reducer do
  @moduledoc """
  Pure transformations for Vortex's bounded current-race projection.

  Updates are coalesced by `{topic, key}` before application, so the greatest
  provider event ID wins independently of delivery order. The reducer owns no
  timers, processes, provider clients, PubSub, or historical state.
  """

  alias Vortex.F1.Live.Event
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow
  alias Vortex.F1.Types

  @maximum_rows 22
  @empty_summary %{
    accepted: 0,
    coalesced: 0,
    duplicate: 0,
    malformed: 0,
    older: 0,
    unknown: 0
  }

  @typedoc "Counts one batch's deterministic acceptance decisions."
  @type summary :: %{
          accepted: non_neg_integer(),
          coalesced: non_neg_integer(),
          duplicate: non_neg_integer(),
          malformed: non_neg_integer(),
          older: non_neg_integer(),
          unknown: non_neg_integer()
        }

  @doc """
  Coalesces and applies normalized events to one current-session projection.

  Equal and older cursors leave the projection version unchanged. A batch with
  at least one accepted logical update advances the local sequence exactly once.
  """
  @spec apply_batch(RaceProjection.t(), [Event.t() | term()], DateTime.t()) ::
          {RaceProjection.t(), summary()}
  def apply_batch(%RaceProjection{} = projection, events, %DateTime{} = captured_at)
      when is_list(events) do
    {candidates, summary} = select_candidates(projection, events)

    if map_size(candidates) == 0 do
      {projection, summary}
    else
      updated =
        candidates
        |> Map.values()
        |> Enum.sort_by(&{&1.id, &1.topic, &1.key})
        |> Enum.reduce(projection, &apply_event/2)
        |> finalize_batch(captured_at)

      {updated, %{summary | accepted: map_size(candidates)}}
    end
  end

  @doc "Starts a new current session and discards every value from the prior generation."
  @spec begin_session(RaceProjection.t(), Session.t(), Types.source(), DateTime.t()) ::
          RaceProjection.t()
  def begin_session(
        %RaceProjection{} = projection,
        %Session{} = session,
        source,
        %DateTime{} = captured_at
      ) do
    %RaceProjection{
      session_key: session.key,
      generation: projection.generation + 1,
      sequence: 0,
      captured_at: captured_at,
      stale_since: nil,
      status: :connecting,
      source: source,
      rows: [],
      session: session,
      cursors: %{}
    }
  end

  @doc "Atomically replaces a projection from a coherent provider reconciliation."
  @spec reconcile(RaceProjection.t(), RaceProjection.t(), DateTime.t()) :: RaceProjection.t()
  def reconcile(
        %RaceProjection{} = current,
        %RaceProjection{} = candidate,
        %DateTime{} = captured_at
      ) do
    same_session? = current.session_key == candidate.session_key

    %RaceProjection{
      candidate
      | generation: if(same_session?, do: current.generation, else: current.generation + 1),
        sequence: if(same_session?, do: current.sequence + 1, else: 1),
        captured_at: captured_at,
        rows: order_and_bound(candidate.rows),
        cursors: bounded_cursors(candidate.cursors)
    }
  end

  defp select_candidates(projection, events) do
    Enum.reduce(events, {%{}, @empty_summary}, fn event, {candidates, summary} ->
      select_candidate(projection, event, candidates, summary)
    end)
  end

  defp select_candidate(_projection, %Event{topic: topic}, candidates, summary)
       when topic not in [:driver, :position, :interval, :lap, :stint, :pit, :session] do
    {candidates, increment(summary, :unknown)}
  end

  defp select_candidate(projection, %Event{} = event, candidates, summary) do
    if Event.valid?(event) and event.session_key == projection.session_key do
      classify_candidate(projection, event, candidates, summary)
    else
      {candidates, increment(summary, :malformed)}
    end
  end

  defp select_candidate(_projection, _event, candidates, summary) do
    {candidates, increment(summary, :malformed)}
  end

  defp classify_candidate(projection, event, candidates, summary) do
    cursor_key = {event.topic, event.key}
    committed_id = Map.get(projection.cursors, cursor_key, -1)

    cond do
      event.id < committed_id ->
        {candidates, increment(summary, :older)}

      event.id == committed_id ->
        {candidates, increment(summary, :duplicate)}

      true ->
        classify_uncommitted(event, cursor_key, candidates, summary)
    end
  end

  defp classify_uncommitted(event, cursor_key, candidates, summary) do
    case Map.get(candidates, cursor_key) do
      nil ->
        {Map.put(candidates, cursor_key, event), summary}

      %Event{id: id} when event.id > id ->
        {Map.put(candidates, cursor_key, event), increment(summary, :coalesced)}

      %Event{id: id} when event.id == id ->
        {candidates, increment(summary, :duplicate)}

      %Event{} ->
        {candidates, increment(summary, :coalesced)}
    end
  end

  defp apply_event(
         %Event{topic: :session, changes: %{session: %Session{} = session}} = event,
         projection
       ) do
    projection
    |> Map.put(:session, session)
    |> put_cursor(event)
  end

  defp apply_event(%Event{} = event, projection) do
    row_id = "timing-row-#{event.key}"
    row = Enum.find(projection.rows, &(&1.id == row_id)) || %TimingRow{id: row_id}
    updated_row = struct(row, event.changes)
    rows = [updated_row | Enum.reject(projection.rows, &(&1.id == row_id))]

    projection
    |> Map.put(:rows, rows)
    |> put_cursor(event)
  end

  defp put_cursor(projection, event) do
    cursor_key = {event.topic, event.key}
    %{projection | cursors: Map.put(projection.cursors, cursor_key, event.id)}
  end

  defp finalize_batch(projection, captured_at) do
    %{
      projection
      | sequence: projection.sequence + 1,
        captured_at: captured_at,
        rows: order_and_bound(projection.rows),
        cursors: bounded_cursors(projection.cursors)
    }
  end

  defp order_and_bound(rows) do
    rows
    |> Enum.filter(&match?(%TimingRow{}, &1))
    |> Enum.sort_by(&row_sort_key/1)
    |> Enum.take(@maximum_rows)
  end

  defp row_sort_key(%TimingRow{position: position, id: id}) do
    {position || 999, id}
  end

  defp bounded_cursors(cursors) when is_map(cursors) do
    cursors
    |> Enum.filter(fn
      {{topic, key}, id} ->
        Event.known_topic?(topic) and is_binary(key) and is_integer(id) and id >= 0

      _entry ->
        false
    end)
    |> Map.new()
  end

  defp bounded_cursors(_cursors) do
    %{}
  end

  defp increment(summary, key) do
    Map.update!(summary, key, &(&1 + 1))
  end
end
