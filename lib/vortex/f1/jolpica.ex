defmodule Vortex.F1.Jolpica do
  @moduledoc """
  Jolpica implementation of the normalized reference-data provider.

  The adapter validates request identity, follows bounded pagination, and maps
  provider JSON into Vortex structs. Provider maps never leave this module.
  """

  @behaviour Vortex.F1.ReferenceProvider

  alias Vortex.F1.Constructor
  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.Driver
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Error
  alias Vortex.F1.Jolpica.Client
  alias Vortex.F1.Meeting
  alias Vortex.F1.Result
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @page_limit 100
  @maximum_pages 20

  @session_fields [
    {:practice_1, "FirstPractice"},
    {:practice_2, "SecondPractice"},
    {:practice_3, "ThirdPractice"},
    {:sprint_shootout, "SprintShootout"},
    {:sprint_shootout, "SprintQualifying"},
    {:sprint, "Sprint"},
    {:qualifying, "Qualifying"}
  ]

  @doc "Returns a normalized season schedule using the production HTTP client."
  @impl true
  @spec schedule(Types.season()) ::
          {:ok, [Meeting.t()]} | {:error, Error.t()}
  def schedule(season) do
    schedule(season, [])
  end

  @doc "Returns a normalized season schedule with injectable client options."
  @spec schedule(term(), keyword()) :: {:ok, [Meeting.t()]} | {:error, Error.t()}
  def schedule(season, options) do
    options = Keyword.put(options, :operation, :schedule)

    with {:ok, normalized_season} <- validate_season(season),
         {:ok, races} <-
           fetch_all(
             "#{normalized_season}/races/",
             ["MRData", "RaceTable", "Races"],
             options
           ) do
      normalize_collection(races, &normalize_meeting/1)
    end
  end

  @doc "Returns a normalized completed-session classification using the production client."
  @impl true
  @spec results(Types.season(), Types.round(), Types.session_kind()) ::
          {:ok, [Result.t()]} | {:error, Error.t()}
  def results(season, round, session_kind) do
    results(season, round, session_kind, [])
  end

  @doc "Returns a normalized completed-session classification with injectable client options."
  @spec results(term(), term(), term(), keyword()) ::
          {:ok, [Result.t()]} | {:error, Error.t()}
  def results(season, round, session_kind, options) do
    options = Keyword.put(options, :operation, :results)

    with {:ok, normalized_season} <- validate_season(season),
         {:ok, normalized_round} <- validate_round(round),
         {:ok, normalized_kind} <- validate_session_kind(session_kind),
         {:ok, endpoint} <- result_endpoint(normalized_kind),
         {:ok, races} <-
           fetch_all(
             "#{normalized_season}/#{normalized_round}/#{endpoint}/",
             ["MRData", "RaceTable", "Races"],
             options
           ) do
      normalize_results(races, normalized_season, normalized_round, normalized_kind)
    end
  end

  @doc "Returns normalized driver standings using the production HTTP client."
  @impl true
  @spec driver_standings(Types.season()) ::
          {:ok, [DriverStanding.t()]} | {:error, Error.t()}
  def driver_standings(season) do
    driver_standings(season, [])
  end

  @doc "Returns normalized driver standings with injectable client options."
  @spec driver_standings(term(), keyword()) ::
          {:ok, [DriverStanding.t()]} | {:error, Error.t()}
  def driver_standings(season, options) do
    options = Keyword.put(options, :operation, :driver_standings)

    with {:ok, normalized_season} <- validate_season(season),
         {:ok, lists} <-
           fetch_all(
             "#{normalized_season}/driverstandings/",
             ["MRData", "StandingsTable", "StandingsLists"],
             options
           ) do
      lists
      |> Enum.flat_map(&Map.get(&1, "DriverStandings", []))
      |> normalize_collection(&normalize_driver_standing/1)
    end
  end

  @doc "Returns normalized constructor standings using the production HTTP client."
  @impl true
  @spec constructor_standings(Types.season()) ::
          {:ok, [ConstructorStanding.t()]} | {:error, Error.t()}
  def constructor_standings(season) do
    constructor_standings(season, [])
  end

  @doc "Returns normalized constructor standings with injectable client options."
  @spec constructor_standings(term(), keyword()) ::
          {:ok, [ConstructorStanding.t()]} | {:error, Error.t()}
  def constructor_standings(season, options) do
    options = Keyword.put(options, :operation, :constructor_standings)

    with {:ok, normalized_season} <- validate_season(season),
         {:ok, lists} <-
           fetch_all(
             "#{normalized_season}/constructorstandings/",
             ["MRData", "StandingsTable", "StandingsLists"],
             options
           ) do
      lists
      |> Enum.flat_map(&Map.get(&1, "ConstructorStandings", []))
      |> normalize_collection(&normalize_constructor_standing/1)
    end
  end

  defp fetch_all(path, collection_path, options) do
    fetch_page(path, collection_path, options, 0, 0, [])
  end

  defp fetch_page(_path, _collection_path, _options, _offset, @maximum_pages, _items) do
    {:error, Error.new(:schema, source: :jolpica)}
  end

  defp fetch_page(path, collection_path, options, offset, page_count, accumulated) do
    request_options = Keyword.get(options, :request_options, [])

    case Client.get(path,
           params: [limit: @page_limit, offset: offset],
           operation: Keyword.get(options, :operation),
           request_options: request_options
         ) do
      {:ok, body} ->
        continue_pagination(
          body,
          path,
          collection_path,
          options,
          offset,
          page_count,
          accumulated
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp continue_pagination(
         body,
         path,
         collection_path,
         options,
         offset,
         page_count,
         accumulated
       ) do
    with {:ok, items} <- fetch_collection(body, collection_path),
         {:ok, total} <- metadata_integer(body, "total"),
         {:ok, limit} <- metadata_integer(body, "limit"),
         true <- limit > 0 do
      combined = accumulated ++ items
      next_offset = offset + limit

      if next_offset < total do
        fetch_page(
          path,
          collection_path,
          options,
          next_offset,
          page_count + 1,
          combined
        )
      else
        {:ok, combined}
      end
    else
      _invalid -> {:error, Error.new(:schema, source: :jolpica)}
    end
  end

  defp fetch_collection(body, collection_path) do
    case get_in(body, collection_path) do
      items when is_list(items) -> {:ok, items}
      _invalid -> {:error, :invalid_collection}
    end
  end

  defp metadata_integer(body, key) do
    body
    |> get_in(["MRData", key])
    |> parse_integer()
  end

  defp normalize_collection(items, normalizer) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, accumulated} ->
      case normalizer.(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | accumulated]}}
        {:error, _reason} -> {:halt, {:error, Error.new(:schema, source: :jolpica)}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_meeting(race) when is_map(race) do
    with {:ok, season} <- race |> Map.get("season") |> Types.season(),
         {:ok, round} <- race |> Map.get("round") |> Types.round() do
      meeting_id = Types.safe_ref("#{season}-#{round}", :meeting)

      sessions =
        @session_fields
        |> Enum.flat_map(fn {kind, field} ->
          case Map.get(race, field) do
            schedule when is_map(schedule) -> [normalize_session(season, round, kind, schedule)]
            _missing -> []
          end
        end)
        |> Kernel.++([normalize_session(season, round, :race, race)])
        |> Enum.uniq_by(& &1.kind)
        |> Enum.sort_by(&session_order(&1.kind))

      location = get_in(race, ["Circuit", "Location"]) || %{}

      {:ok,
       %Meeting{
         id: meeting_id,
         season: season,
         round: round,
         name: Types.display(Map.get(race, "raceName")),
         circuit_name: Types.display(get_in(race, ["Circuit", "circuitName"])),
         locality: Types.display(Map.get(location, "locality")),
         country: Types.display(Map.get(location, "country")),
         starts_at: parse_datetime(Map.get(race, "date"), Map.get(race, "time")),
         sessions: sessions
       }}
    end
  end

  defp normalize_meeting(_race) do
    {:error, :invalid_meeting}
  end

  defp normalize_session(season, round, kind, schedule) do
    %Session{
      id: Types.safe_ref("#{season}-#{round}-#{kind}", :session),
      kind: kind,
      name: session_name(kind),
      starts_at: parse_datetime(Map.get(schedule, "date"), Map.get(schedule, "time"))
    }
  end

  defp normalize_results(races, season, round, kind) do
    result_field = result_field(kind)

    races
    |> Enum.flat_map(&Map.get(&1, result_field, []))
    |> normalize_collection(&normalize_result(&1, season, round, kind))
  end

  defp normalize_result(result, season, round, kind) when is_map(result) do
    with {:ok, position} <- parse_positive_integer(Map.get(result, "position")),
         {:ok, driver} <- normalize_driver(Map.get(result, "Driver")),
         {:ok, constructor} <- normalize_constructor(Map.get(result, "Constructor")) do
      id = Types.safe_ref("#{season}-#{round}-#{kind}-#{driver.ref}", :result)
      q1 = optional_display(Map.get(result, "Q1"))
      q2 = optional_display(Map.get(result, "Q2"))
      q3 = optional_display(Map.get(result, "Q3"))

      {:ok,
       %Result{
         id: id,
         position: position,
         driver: driver,
         constructor: constructor,
         grid: optional_non_negative_integer(Map.get(result, "grid")),
         laps: optional_non_negative_integer(Map.get(result, "laps")),
         time: result_time(result, kind, q1, q2, q3),
         q1: q1,
         q2: q2,
         q3: q3,
         gap: Types.display(Map.get(result, "gap")),
         status: Types.display(Map.get(result, "status")),
         points: number(Map.get(result, "points")),
         fastest_lap: optional_display(get_in(result, ["FastestLap", "Time", "time"]))
       }}
    end
  end

  defp normalize_result(_result, _season, _round, _kind) do
    {:error, :invalid_result}
  end

  defp result_time(_result, :qualifying, q1, q2, q3) do
    q3 || q2 || q1 || "—"
  end

  defp result_time(result, _kind, _q1, _q2, _q3) do
    Types.display(get_in(result, ["Time", "time"]))
  end

  defp normalize_driver_standing(standing) when is_map(standing) do
    with {:ok, position} <- parse_positive_integer(Map.get(standing, "position")),
         {:ok, driver} <- normalize_driver(Map.get(standing, "Driver")),
         {:ok, constructors} <-
           normalize_collection(Map.get(standing, "Constructors", []), &normalize_constructor/1) do
      {:ok,
       %DriverStanding{
         id: "driver-standing-" <> driver.ref,
         position: position,
         driver: driver,
         constructors: constructors,
         points: number(Map.get(standing, "points")),
         wins: optional_non_negative_integer(Map.get(standing, "wins")) || 0
       }}
    end
  end

  defp normalize_driver_standing(_standing) do
    {:error, :invalid_driver_standing}
  end

  defp normalize_constructor_standing(standing) when is_map(standing) do
    with {:ok, position} <- parse_positive_integer(Map.get(standing, "position")),
         {:ok, constructor} <- normalize_constructor(Map.get(standing, "Constructor")) do
      {:ok,
       %ConstructorStanding{
         id: "constructor-standing-" <> constructor.ref,
         position: position,
         constructor: constructor,
         points: number(Map.get(standing, "points")),
         wins: optional_non_negative_integer(Map.get(standing, "wins")) || 0
       }}
    end
  end

  defp normalize_constructor_standing(_standing) do
    {:error, :invalid_constructor_standing}
  end

  defp normalize_driver(driver) when is_map(driver) do
    given_name = Types.display(Map.get(driver, "givenName"))
    family_name = Types.display(Map.get(driver, "familyName"))

    {:ok,
     %Driver{
       ref: Types.safe_ref(Map.get(driver, "driverId"), :driver),
       number: optional_non_negative_integer(Map.get(driver, "permanentNumber")),
       code: Types.display(Map.get(driver, "code")),
       first_name: given_name,
       last_name: family_name,
       display_name: Types.display(given_name <> " " <> family_name),
       nationality: Types.display(Map.get(driver, "nationality"))
     }}
  end

  defp normalize_driver(_driver) do
    {:error, :invalid_driver}
  end

  defp normalize_constructor(constructor) when is_map(constructor) do
    {:ok,
     %Constructor{
       ref: Types.safe_ref(Map.get(constructor, "constructorId"), :constructor),
       name: Types.display(Map.get(constructor, "name")),
       nationality: Types.display(Map.get(constructor, "nationality"))
     }}
  end

  defp normalize_constructor(_constructor) do
    {:error, :invalid_constructor}
  end

  defp validate_season(value) do
    case Types.season(value) do
      {:ok, season} -> {:ok, season}
      {:error, _reason} -> {:error, Error.new(:not_found, source: :jolpica)}
    end
  end

  defp validate_round(value) do
    case Types.round(value) do
      {:ok, round} -> {:ok, round}
      {:error, _reason} -> {:error, Error.new(:not_found, source: :jolpica)}
    end
  end

  defp validate_session_kind(value) do
    case Types.session_kind(value) do
      {:ok, kind} -> {:ok, kind}
      {:error, _reason} -> {:error, Error.new(:not_found, source: :jolpica)}
    end
  end

  defp result_endpoint(:race) do
    {:ok, "results"}
  end

  defp result_endpoint(:qualifying) do
    {:ok, "qualifying"}
  end

  defp result_endpoint(:sprint) do
    {:ok, "sprint"}
  end

  defp result_endpoint(_unsupported) do
    {:error, Error.new(:not_found, source: :jolpica)}
  end

  defp result_field(:race) do
    "Results"
  end

  defp result_field(:qualifying) do
    "QualifyingResults"
  end

  defp result_field(:sprint) do
    "SprintResults"
  end

  defp session_order(kind) do
    Enum.find_index(Types.session_kinds(), &(&1 == kind)) || 99
  end

  defp session_name(:practice_1) do
    "Practice 1"
  end

  defp session_name(:practice_2) do
    "Practice 2"
  end

  defp session_name(:practice_3) do
    "Practice 3"
  end

  defp session_name(:sprint_shootout) do
    "Sprint Shootout"
  end

  defp session_name(:sprint) do
    "Sprint"
  end

  defp session_name(:qualifying) do
    "Qualifying"
  end

  defp session_name(:race) do
    "Race"
  end

  defp parse_datetime(date, time) when is_binary(date) do
    normalized_time = if is_binary(time), do: time, else: "00:00:00Z"

    case DateTime.from_iso8601(date <> "T" <> normalized_time) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_date, _time) do
    nil
  end

  defp parse_positive_integer(value) do
    with {:ok, integer} <- parse_integer(value),
         true <- integer > 0 do
      {:ok, integer}
    else
      _invalid -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(value) when is_integer(value) do
    {:ok, value}
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(_value) do
    {:error, :invalid_integer}
  end

  defp optional_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, integer} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp number(value) when is_integer(value) do
    value / 1
  end

  defp number(value) when is_float(value) do
    value
  end

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _invalid -> 0.0
    end
  end

  defp number(_value) do
    0.0
  end

  defp optional_display(value) when is_binary(value) do
    Types.display(value)
  end

  defp optional_display(_value) do
    nil
  end
end
