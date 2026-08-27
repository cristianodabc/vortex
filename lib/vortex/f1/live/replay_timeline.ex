defmodule Vortex.F1.Live.ReplayTimeline do
  @moduledoc """
  A bounded immutable event timeline for one historical timing session.

  The timeline stores normalized, timing-relevant events rather than periodic
  projections. A viewer reconstructs only its current cursor through the pure
  reducer, so playback does not retain snapshots or mutate shared live state.
  """

  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.Reducer
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @default_max_events 50_000

  @typedoc "A bounded historical event sequence shared read-only across viewers."
  @type t :: %__MODULE__{
          session: Session.t(),
          source: Types.source(),
          events: [Event.t()],
          event_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          truncated?: boolean()
        }

  defstruct session: %Session{},
            source: :open_f1,
            events: [],
            event_count: 0,
            duration_ms: 0,
            truncated?: false

  @doc "Builds a chronologically ordered, topic-limited historical timeline."
  @spec new(Session.t(), Types.source(), [Event.t() | term()], keyword()) :: t()
  def new(%Session{} = session, source, events, options \\ []) when is_list(events) do
    maximum = normalize_max_events(Keyword.get(options, :max_events, @default_max_events))

    eligible =
      events
      |> Enum.filter(&eligible?(&1, session.key))
      |> Enum.sort_by(&event_sort_key/1)

    bounded = Enum.take(eligible, maximum)

    %__MODULE__{
      session: session,
      source: source,
      events: bounded,
      event_count: length(bounded),
      duration_ms: duration_ms(bounded),
      truncated?: length(eligible) > length(bounded)
    }
  end

  @doc "Returns a copy capped to at most `maximum` events."
  @spec limit(t(), pos_integer()) :: t()
  def limit(%__MODULE__{} = timeline, maximum) when is_integer(maximum) and maximum > 0 do
    events = Enum.take(timeline.events, maximum)

    %{
      timeline
      | events: events,
        event_count: length(events),
        duration_ms: duration_ms(events),
        truncated?: timeline.truncated? or timeline.event_count > length(events)
    }
  end

  @doc "Reconstructs the replay projection at an event-count cursor."
  @spec project(t(), integer()) :: RaceProjection.t()
  def project(%__MODULE__{} = timeline, cursor) when is_integer(cursor) do
    bounded_cursor = cursor |> max(0) |> min(timeline.event_count)
    events = Enum.take(timeline.events, bounded_cursor)
    captured_at = captured_at(events, timeline.session)

    projection =
      %RaceProjection{}
      |> Reducer.begin_session(timeline.session, timeline.source, captured_at)
      |> apply_events(events, captured_at)

    %{projection | status: :replay}
  end

  @doc "Returns the real event-time delay after a cursor, or `nil` at the end."
  @spec delay_after(t(), non_neg_integer()) :: non_neg_integer() | nil
  def delay_after(%__MODULE__{events: events, event_count: count}, cursor)
      when is_integer(cursor) and cursor >= 0 and cursor < count do
    current = Enum.at(events, max(cursor - 1, 0))
    next = Enum.at(events, cursor)
    event_delay(current, next)
  end

  def delay_after(%__MODULE__{}, _cursor) do
    nil
  end

  defp eligible?(%Event{} = event, session_key) do
    Event.known_topic?(event.topic) and Event.valid?(event) and event.session_key == session_key
  end

  defp eligible?(_event, _session_key) do
    false
  end

  defp event_sort_key(%Event{occurred_at: %DateTime{} = occurred_at, id: id}) do
    {DateTime.to_unix(occurred_at, :microsecond), id}
  end

  defp event_sort_key(%Event{id: id}) do
    {0, id}
  end

  defp duration_ms([]) do
    0
  end

  defp duration_ms([_event]) do
    0
  end

  defp duration_ms(events) do
    event_delay(List.first(events), List.last(events))
  end

  defp event_delay(
         %Event{occurred_at: %DateTime{} = first},
         %Event{occurred_at: %DateTime{} = second}
       ) do
    second
    |> DateTime.diff(first, :millisecond)
    |> max(0)
  end

  defp event_delay(_first, _second) do
    0
  end

  defp captured_at([%Event{occurred_at: %DateTime{} = first} | _events], _session) do
    first
  end

  defp captured_at(_events, %Session{starts_at: %DateTime{} = starts_at}) do
    starts_at
  end

  defp captured_at(_events, _session) do
    DateTime.from_unix!(0)
  end

  defp apply_events(projection, [], _captured_at) do
    projection
  end

  defp apply_events(projection, events, captured_at) do
    {updated, _summary} = Reducer.apply_batch(projection, events, captured_at)
    updated
  end

  defp normalize_max_events(value) when is_integer(value) and value > 0 do
    value
  end

  defp normalize_max_events(_value) do
    @default_max_events
  end
end
