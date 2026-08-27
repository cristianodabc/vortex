defmodule Vortex.F1.OpenF1 do
  @moduledoc """
  OpenF1 historical replay adapter.

  Historical race sessions from 2023 onward are assembled from the documented
  sessions, drivers, position, intervals, laps, stints, and pit endpoints. The
  adapter validates provider strings and colors, assigns deterministic cursors,
  and emits only normalized Vortex events.
  """

  @behaviour Vortex.F1.ReplayProvider

  alias Vortex.F1.Driver
  alias Vortex.F1.Error
  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.OpenF1.Client
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @earliest_replay_season 2023
  @collection_limits %{
    drivers: 30,
    position: 10_000,
    intervals: 25_000,
    laps: 5_000,
    stints: 500,
    pit: 500
  }

  @doc "Lists normalized historical race sessions using the production HTTP client."
  @impl true
  @spec sessions(Types.season()) :: {:ok, [Session.t()]} | {:error, Error.t()}
  def sessions(season) do
    sessions(season, [])
  end

  @doc "Lists historical race sessions with injectable client options for tests."
  @spec sessions(term(), keyword()) :: {:ok, [Session.t()]} | {:error, Error.t()}
  def sessions(season, options) do
    options = Keyword.put(options, :operation, :replay_sessions)

    with {:ok, normalized_season} <- replay_season(season),
         {:ok, rows} <-
           request("sessions", [year: normalized_season, session_name: "Race"], options),
         {:ok, normalized} <- normalize_collection(rows, &normalize_session/1) do
      sessions =
        normalized
        |> Enum.filter(&completed_session?/1)
        |> Enum.sort_by(&session_sort_key/1, :desc)

      {:ok, sessions}
    end
  end

  @doc "Loads one normalized historical timeline using the production HTTP client."
  @impl true
  @spec timeline(Types.session_key()) ::
          {:ok, ReplayTimeline.t()} | {:error, Error.t()}
  def timeline(session_key) do
    timeline(session_key, [])
  end

  @doc "Loads one historical timeline with injectable client options for tests."
  @spec timeline(term(), keyword()) ::
          {:ok, ReplayTimeline.t()} | {:error, Error.t()}
  def timeline(session_key, options) when is_integer(session_key) and session_key >= 0 do
    with {:ok, session_rows} <- request("sessions", [session_key: session_key], options),
         {:ok, session} <- exactly_one_session(session_rows),
         {:ok, drivers} <- limited_request(:drivers, session_key, options),
         {:ok, positions} <- limited_request(:position, session_key, options),
         {:ok, intervals} <- limited_request(:intervals, session_key, options),
         {:ok, laps} <- limited_request(:laps, session_key, options),
         {:ok, stints} <- limited_request(:stints, session_key, options),
         {:ok, pits} <- limited_request(:pit, session_key, options),
         {:ok, events} <-
           normalize_events(session, drivers, positions, intervals, laps, stints, pits) do
      {:ok, ReplayTimeline.new(session, :open_f1, events)}
    end
  end

  def timeline(_session_key, _options) do
    {:error, Error.new(:not_found, source: :open_f1)}
  end

  defp limited_request(endpoint, session_key, options) do
    endpoint_name = Atom.to_string(endpoint)

    case request(endpoint_name, [session_key: session_key], options) do
      {:ok, rows} -> {:ok, Enum.take(rows, Map.fetch!(@collection_limits, endpoint))}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp request(path, params, options) do
    Client.get(path,
      params: params,
      operation: Keyword.get(options, :operation, :replay_timeline),
      request_options: Keyword.get(options, :request_options, [])
    )
  end

  defp exactly_one_session([row | _rows]) do
    normalize_session(row)
  end

  defp exactly_one_session(_rows) do
    {:error, Error.new(:not_found, source: :open_f1)}
  end

  defp normalize_session(row) when is_map(row) do
    with {:ok, key} <- non_negative_integer(Map.get(row, "session_key")),
         {:ok, starts_at} <- datetime(Map.get(row, "date_start")) do
      name =
        [Types.display(Map.get(row, "country_name")), Types.display(Map.get(row, "session_name"))]
        |> Enum.reject(&(&1 == "—"))
        |> Enum.join(" · ")

      {:ok,
       %Session{
         id: Types.safe_ref(key, :session),
         key: key,
         kind: session_kind(Map.get(row, "session_name")),
         name: Types.display(name, fallback: "Historical race"),
         starts_at: starts_at,
         ends_at: optional_datetime(Map.get(row, "date_end")),
         status: :replay
       }}
    else
      _invalid -> {:error, Error.new(:schema, source: :open_f1)}
    end
  end

  defp normalize_session(_row) do
    {:error, Error.new(:schema, source: :open_f1)}
  end

  defp normalize_events(session, drivers, positions, intervals, laps, stints, pits) do
    with {:ok, driver_events} <- normalize_collection(drivers, &driver_event(&1, session)),
         {:ok, position_events} <- normalize_collection(positions, &position_event/1),
         {:ok, interval_events} <- normalize_collection(intervals, &interval_event/1),
         {:ok, lap_events} <- lap_events(laps),
         {:ok, stint_events} <- stint_events(stints, laps, session),
         {:ok, pit_events} <- normalize_collection(pits, &pit_event/1) do
      events =
        driver_events ++
          position_events ++ interval_events ++ lap_events ++ stint_events ++ pit_events

      {:ok, assign_event_ids(events)}
    end
  end

  defp driver_event(row, session) do
    with {:ok, session_key} <- non_negative_integer(Map.get(row, "session_key")),
         {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
         true <- session_key == session.key do
      colour = Types.team_colour(Map.get(row, "team_colour"))
      driver_ref = Types.safe_ref(number, :driver)

      driver = %Driver{
        ref: driver_ref,
        number: number,
        code: Types.display(Map.get(row, "name_acronym")),
        first_name: Types.display(Map.get(row, "first_name")),
        last_name: Types.display(Map.get(row, "last_name")),
        display_name: Types.display(Map.get(row, "full_name")),
        team_ref: Types.safe_ref(Map.get(row, "team_name"), :constructor),
        team_name: Types.display(Map.get(row, "team_name")),
        team_colour: colour
      }

      {:ok,
       event_seed(session_key, :driver, driver_ref, session.starts_at, %{
         driver: driver,
         team_colour: colour
       })}
    else
      _invalid -> {:error, :invalid_driver}
    end
  end

  defp position_event(row) do
    with {:ok, session_key} <- non_negative_integer(Map.get(row, "session_key")),
         {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
         {:ok, occurred_at} <- datetime(Map.get(row, "date")),
         {:ok, position} <- positive_integer(Map.get(row, "position")) do
      {:ok,
       event_seed(session_key, :position, Types.safe_ref(number, :driver), occurred_at, %{
         position: position
       })}
    else
      _invalid -> {:error, :invalid_position}
    end
  end

  defp interval_event(row) do
    with {:ok, session_key} <- non_negative_integer(Map.get(row, "session_key")),
         {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
         {:ok, occurred_at} <- datetime(Map.get(row, "date")) do
      {:ok,
       event_seed(session_key, :interval, Types.safe_ref(number, :driver), occurred_at, %{
         gap: timing_value(Map.get(row, "gap_to_leader"), "Leader"),
         interval: timing_value(Map.get(row, "interval"), "—")
       })}
    else
      _invalid -> {:error, :invalid_interval}
    end
  end

  defp lap_events(rows) do
    rows
    |> Enum.sort_by(&lap_sort_key/1)
    |> Enum.reduce_while({:ok, [], %{}}, fn row, {:ok, events, best_by_driver} ->
      case lap_event(row, best_by_driver) do
        {:ok, event, next_best} -> {:cont, {:ok, [event | events], next_best}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events, _best} -> {:ok, Enum.reverse(events)}
      {:error, _reason} -> {:error, Error.new(:schema, source: :open_f1)}
    end
  end

  defp lap_event(row, best_by_driver) do
    with {:ok, session_key} <- non_negative_integer(Map.get(row, "session_key")),
         {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
         {:ok, occurred_at} <- datetime(Map.get(row, "date_start")),
         {:ok, duration} <- positive_number(Map.get(row, "lap_duration")) do
      best = min(duration, Map.get(best_by_driver, number, duration))

      event =
        event_seed(session_key, :lap, Types.safe_ref(number, :driver), occurred_at, %{
          last_lap: format_duration(duration),
          best_lap: format_duration(best)
        })

      {:ok, event, Map.put(best_by_driver, number, best)}
    else
      _invalid -> {:error, :invalid_lap}
    end
  end

  defp stint_events(rows, laps, session) do
    lap_dates = lap_date_index(laps)

    normalize_collection(rows, fn row ->
      with {:ok, session_key} <- non_negative_integer(Map.get(row, "session_key")),
           {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
           {:ok, lap_start} <- positive_integer(Map.get(row, "lap_start")) do
        occurred_at = Map.get(lap_dates, {number, lap_start}, session.starts_at)

        {:ok,
         event_seed(session_key, :stint, Types.safe_ref(number, :driver), occurred_at, %{
           tyre: tyre(Map.get(row, "compound")),
           tyre_age: optional_non_negative_integer(Map.get(row, "tyre_age_at_start"))
         })}
      else
        _invalid -> {:error, :invalid_stint}
      end
    end)
  end

  defp pit_event(row) do
    with {:ok, session_key} <- non_negative_integer(Map.get(row, "session_key")),
         {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
         {:ok, occurred_at} <- datetime(Map.get(row, "date")) do
      {:ok,
       event_seed(session_key, :pit, Types.safe_ref(number, :driver), occurred_at, %{
         pit_state: :pit,
         status: "In pit"
       })}
    else
      _invalid -> {:error, :invalid_pit}
    end
  end

  defp event_seed(session_key, topic, key, occurred_at, changes) do
    %{
      session_key: session_key,
      topic: topic,
      key: key,
      occurred_at: occurred_at,
      changes: changes
    }
  end

  defp assign_event_ids(seeds) do
    seeds
    |> Enum.sort_by(&seed_sort_key/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {seed, id} -> struct(Event, Map.put(seed, :id, id)) end)
  end

  defp seed_sort_key(seed) do
    time =
      case seed.occurred_at do
        %DateTime{} = occurred_at -> DateTime.to_unix(occurred_at, :microsecond)
        _missing -> 0
      end

    {time, topic_order(seed.topic), seed.key}
  end

  defp topic_order(:driver) do
    0
  end

  defp topic_order(:stint) do
    1
  end

  defp topic_order(:position) do
    2
  end

  defp topic_order(:interval) do
    3
  end

  defp topic_order(:lap) do
    4
  end

  defp topic_order(:pit) do
    5
  end

  defp normalize_collection(rows, normalizer) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, accumulated} ->
      case normalizer.(row) do
        {:ok, value} -> {:cont, {:ok, [value | accumulated]}}
        {:error, _reason} -> {:halt, {:error, Error.new(:schema, source: :open_f1)}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp replay_season(value) do
    case Types.season(value) do
      {:ok, season} when season >= @earliest_replay_season -> {:ok, season}
      _invalid -> {:error, Error.new(:not_found, source: :open_f1)}
    end
  end

  defp session_kind("Race") do
    :race
  end

  defp session_kind(_name) do
    nil
  end

  defp session_sort_key(%Session{starts_at: %DateTime{} = starts_at}) do
    DateTime.to_unix(starts_at)
  end

  defp session_sort_key(_session) do
    0
  end

  defp completed_session?(%Session{ends_at: %DateTime{} = ends_at}) do
    DateTime.compare(ends_at, DateTime.utc_now()) in [:lt, :eq]
  end

  defp completed_session?(%Session{starts_at: %DateTime{} = starts_at}) do
    DateTime.compare(starts_at, DateTime.utc_now()) == :lt
  end

  defp completed_session?(_session) do
    false
  end

  defp lap_sort_key(row) do
    case datetime(Map.get(row, "date_start")) do
      {:ok, value} -> DateTime.to_unix(value, :microsecond)
      _invalid -> 0
    end
  end

  defp lap_date_index(rows) do
    Enum.reduce(rows, %{}, fn row, index ->
      with {:ok, number} <- non_negative_integer(Map.get(row, "driver_number")),
           {:ok, lap_number} <- positive_integer(Map.get(row, "lap_number")),
           {:ok, occurred_at} <- datetime(Map.get(row, "date_start")) do
        Map.put(index, {number, lap_number}, occurred_at)
      else
        _invalid -> index
      end
    end)
  end

  defp timing_value(value, _fallback) when is_number(value) do
    "+" <> :erlang.float_to_binary(value / 1, decimals: 3)
  end

  defp timing_value(value, _fallback) when is_binary(value) do
    Types.display(value)
  end

  defp timing_value(_value, fallback) do
    fallback
  end

  defp format_duration(seconds) do
    total_milliseconds = round(seconds * 1_000)
    minutes = div(total_milliseconds, 60_000)
    remainder = rem(total_milliseconds, 60_000)
    seconds_part = div(remainder, 1_000)
    milliseconds = rem(remainder, 1_000)

    Integer.to_string(minutes) <>
      ":" <>
      String.pad_leading(Integer.to_string(seconds_part), 2, "0") <>
      "." <>
      String.pad_leading(Integer.to_string(milliseconds), 3, "0")
  end

  defp tyre("SOFT") do
    :soft
  end

  defp tyre("MEDIUM") do
    :medium
  end

  defp tyre("HARD") do
    :hard
  end

  defp tyre("INTERMEDIATE") do
    :intermediate
  end

  defp tyre("WET") do
    :wet
  end

  defp tyre(_compound) do
    :unknown
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> {:error, :invalid_datetime}
    end
  end

  defp datetime(_value) do
    {:error, :invalid_datetime}
  end

  defp optional_datetime(value) do
    case datetime(value) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp positive_number(value) when is_number(value) and value > 0 do
    {:ok, value / 1}
  end

  defp positive_number(_value) do
    {:error, :invalid_number}
  end

  defp positive_integer(value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp positive_integer(_value) do
    {:error, :invalid_integer}
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp non_negative_integer(_value) do
    {:error, :invalid_integer}
  end

  defp optional_non_negative_integer(value) do
    case non_negative_integer(value) do
      {:ok, integer} -> integer
      {:error, _reason} -> nil
    end
  end
end
