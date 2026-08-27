defmodule Vortex.F1 do
  @moduledoc """
  Provider-neutral public context for Formula 1 reference and timing data.

  Web modules call this context rather than provider adapters. Reference reads
  are normalized before entering the cache, shared across callers, and returned
  with source, version, and freshness metadata. Stale last-known data remains a
  successful `Resource` while sanitized provider failures are returned as errors.
  """

  alias Vortex.F1.Cache
  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Error
  alias Vortex.F1.Meeting
  alias Vortex.F1.Live.RaceState
  alias Vortex.F1.Live.ReplayStore
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Resource
  alias Vortex.F1.Result
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @prior_season_ttl_ms :timer.hours(24)
  @reference_topic "vortex:f1:reference"
  @current_race_topic "vortex:f1:current-race"

  @doc """
  Subscribes the calling process to normalized reference-cache refresh versions.

  Notifications have the shape
  `{Vortex.F1, :reference_refreshed, cache_key, version}` and contain no rows or
  provider payload. LiveViews should subscribe only when connected, then reread
  the coherent resource through this context.
  """
  @spec subscribe_to_reference_updates() :: :ok
  def subscribe_to_reference_updates do
    Phoenix.PubSub.subscribe(Vortex.PubSub, @reference_topic)
  end

  @doc """
  Subscribes the caller to current-race version invalidations.

  Notifications contain only `{Vortex.F1, :current_race_updated, generation,
  sequence}`. Subscribers must subscribe before calling `current_race/0` and
  reread on newer versions.
  """
  @spec subscribe_to_current_race() :: :ok
  def subscribe_to_current_race do
    Phoenix.PubSub.subscribe(Vortex.PubSub, current_race_topic())
  end

  @doc "Returns the canonical bounded current-race projection when live state is available."
  @spec current_race() ::
          {:ok, RaceProjection.t()} | {:error, :inactive | :unavailable}
  def current_race do
    server = race_state_server()

    case GenServer.whereis(server) do
      nil -> {:error, :unavailable}
      _pid -> RaceState.current(server)
    end
  end

  @doc "Lists historical race sessions available for isolated viewer playback."
  @spec replay_sessions(Types.season()) ::
          {:ok, [Session.t()]} | {:error, Error.t()}
  def replay_sessions(season) do
    with {:ok, normalized_season} <- validate_season(season),
         provider when is_atom(provider) <- replay_provider() do
      provider.sessions(normalized_season)
    else
      _missing -> {:error, Error.new(:unavailable)}
    end
  end

  @doc "Opens one bounded shared historical timeline without changing current live state."
  @spec open_replay(Types.session_key()) ::
          {:ok, ReplayTimeline.t()} | {:error, Error.t() | term()}
  def open_replay(session_key) do
    with true <- valid_session_key?(session_key),
         provider when is_atom(provider) <- replay_provider() do
      ReplayStore.open(replay_store_server(), session_key, fn ->
        provider.timeline(session_key)
      end)
    else
      _invalid -> {:error, Error.new(:not_found)}
    end
  end

  @doc """
  Returns a season schedule with cache freshness metadata.

  Current-season schedules revalidate using `:schedule_ttl_ms`; prior seasons
  remain fresh for 24 hours. A failed refresh preserves stale last-known data.
  """
  @spec schedule(Types.season()) ::
          {:ok, Resource.t([Meeting.t()])} | {:error, Error.t()}
  def schedule(season) do
    with {:ok, normalized_season} <- validate_season(season) do
      cached_reference(
        {:schedule, normalized_season},
        schedule_ttl(normalized_season),
        fn provider -> provider.schedule(normalized_season) end
      )
    end
  end

  @doc """
  Returns one completed-session classification with cache freshness metadata.

  Prior-season results remain fresh for the process lifetime. Current-season
  results use the configured 24-hour default and retain stale data on failure.
  """
  @spec results(Types.season(), Types.round(), Types.session_kind()) ::
          {:ok, Resource.t([Result.t()])} | {:error, Error.t()}
  def results(season, round, session_kind) do
    with {:ok, normalized_season} <- validate_season(season),
         {:ok, normalized_round} <- validate_round(round),
         {:ok, normalized_kind} <- validate_session_kind(session_kind) do
      cached_reference(
        {:results, normalized_season, normalized_round, normalized_kind},
        results_ttl(normalized_season),
        fn provider ->
          provider.results(normalized_season, normalized_round, normalized_kind)
        end
      )
    end
  end

  @doc """
  Returns driver championship standings with cache freshness metadata.

  Current standings use the short configured standings TTL; prior seasons remain
  fresh for 24 hours. Stale last-known data remains available during outages.
  """
  @spec driver_standings(Types.season()) ::
          {:ok, Resource.t([DriverStanding.t()])} | {:error, Error.t()}
  def driver_standings(season) do
    with {:ok, normalized_season} <- validate_season(season) do
      cached_reference(
        {:driver_standings, normalized_season},
        standings_ttl(normalized_season),
        fn provider -> provider.driver_standings(normalized_season) end
      )
    end
  end

  @doc """
  Returns constructor championship standings with cache freshness metadata.

  Current standings use the short configured standings TTL; prior seasons remain
  fresh for 24 hours. Stale last-known data remains available during outages.
  """
  @spec constructor_standings(Types.season()) ::
          {:ok, Resource.t([ConstructorStanding.t()])} | {:error, Error.t()}
  def constructor_standings(season) do
    with {:ok, normalized_season} <- validate_season(season) do
      cached_reference(
        {:constructor_standings, normalized_season},
        standings_ttl(normalized_season),
        fn provider -> provider.constructor_standings(normalized_season) end
      )
    end
  end

  defp cached_reference(key, ttl_ms, loader) do
    case reference_provider() do
      provider when is_atom(provider) ->
        Cache.fetch(
          reference_cache_server(),
          key,
          [ttl_ms: ttl_ms, source: reference_source()],
          fn ->
            loader.(provider)
          end
        )

      _missing ->
        {:error, Error.new(:unavailable)}
    end
  end

  defp validate_season(value) do
    case Types.season(value) do
      {:ok, season} -> {:ok, season}
      {:error, _reason} -> {:error, Error.new(:not_found)}
    end
  end

  defp validate_round(value) do
    case Types.round(value) do
      {:ok, round} -> {:ok, round}
      {:error, _reason} -> {:error, Error.new(:not_found)}
    end
  end

  defp validate_session_kind(value) do
    case Types.session_kind(value) do
      {:ok, session_kind} -> {:ok, session_kind}
      {:error, _reason} -> {:error, Error.new(:not_found)}
    end
  end

  defp schedule_ttl(season) do
    if current_season?(season) do
      f1_config(:schedule_ttl_ms, :timer.minutes(15))
    else
      @prior_season_ttl_ms
    end
  end

  defp standings_ttl(season) do
    if current_season?(season) do
      f1_config(:standings_ttl_ms, :timer.minutes(5))
    else
      @prior_season_ttl_ms
    end
  end

  defp results_ttl(season) do
    if current_season?(season) do
      f1_config(:current_results_ttl_ms, :timer.hours(24))
    else
      :infinity
    end
  end

  defp current_season?(season) do
    season == Date.utc_today().year
  end

  defp reference_provider do
    f1_config(:reference_provider, nil)
  end

  defp reference_source do
    f1_config(:reference_source, :jolpica)
  end

  defp reference_cache_server do
    f1_config(:reference_cache_server, Vortex.F1.Cache.Server)
  end

  defp race_state_server do
    f1_config(:race_state_server, RaceState)
  end

  defp replay_provider do
    f1_config(:replay_provider, nil)
  end

  defp replay_store_server do
    f1_config(:replay_store_server, ReplayStore)
  end

  defp valid_session_key?(value) do
    (is_integer(value) and value >= 0) or
      (is_binary(value) and value != "" and byte_size(value) <= 96)
  end

  defp current_race_topic do
    f1_config(:current_race_topic, @current_race_topic)
  end

  defp f1_config(key, default) do
    :vortex
    |> Application.get_env(:f1, [])
    |> Keyword.get(key, default)
  end
end
