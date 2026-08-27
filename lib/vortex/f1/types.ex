defmodule Vortex.F1.Types do
  @moduledoc """
  Defines Vortex-owned scalar types and normalization helpers for F1 data.

  These helpers form the trust boundary between external provider values and the
  rest of the application. They never create atoms from provider input and bound
  every string that may be used in presentation or DOM identifiers.
  """

  import Kernel, except: [round: 1]

  @earliest_season 1950
  @latest_season 2100
  @maximum_round 99
  @maximum_display_length 80
  @maximum_ref_length 64
  @neutral_team_colour "737373"
  @session_kinds [
    :practice_1,
    :practice_2,
    :practice_3,
    :sprint_shootout,
    :sprint,
    :qualifying,
    :race
  ]

  @session_kind_strings %{
    "practice 1" => :practice_1,
    "practice 2" => :practice_2,
    "practice 3" => :practice_3,
    "practice_1" => :practice_1,
    "practice_2" => :practice_2,
    "practice_3" => :practice_3,
    "sprint shootout" => :sprint_shootout,
    "sprint_shootout" => :sprint_shootout,
    "sprint qualifying" => :sprint_shootout,
    "sprint" => :sprint,
    "qualifying" => :qualifying,
    "race" => :race
  }

  @typedoc "A Formula 1 championship season."
  @type season :: 1950..2100

  @typedoc "A race round within a season."
  @type round :: 1..99

  @typedoc "A supported session category."
  @type session_kind ::
          :practice_1
          | :practice_2
          | :practice_3
          | :sprint_shootout
          | :sprint
          | :qualifying
          | :race

  @typedoc "A provider-independent session identifier."
  @type session_key :: non_neg_integer() | String.t()

  @typedoc "A normalized driver identifier safe for use in DOM IDs."
  @type driver_ref :: String.t()

  @typedoc "A normalized constructor identifier safe for use in DOM IDs."
  @type constructor_ref :: String.t()

  @typedoc "A generation changes when the active live session is replaced."
  @type generation :: non_neg_integer()

  @typedoc "A monotonically increasing local projection sequence."
  @type sequence :: non_neg_integer()

  @typedoc "The cache freshness of a normalized resource."
  @type freshness :: :fresh | :stale

  @typedoc "The source that produced normalized data."
  @type source :: :jolpica | :open_f1 | :fixture

  @typedoc "The health and lifecycle state of a current-race projection."
  @type status ::
          :inactive
          | :connecting
          | :live
          | :stale
          | :rate_limited
          | :reconnecting
          | :resyncing
          | :degraded
          | :replay
          | :unavailable

  @typedoc "A normalized provider failure category."
  @type provider_error_kind ::
          :timeout
          | :unauthorized
          | :not_found
          | :rate_limited
          | :upstream
          | :malformed
          | :schema
          | :unavailable

  @doc "Normalizes a supported season from an integer or decimal string."
  @spec season(term()) :: {:ok, season()} | {:error, :invalid_season}
  def season(value) when is_integer(value) and value in @earliest_season..@latest_season do
    {:ok, value}
  end

  def season(value) when is_binary(value) do
    case Integer.parse(value) do
      {season, ""} -> season(season)
      _other -> {:error, :invalid_season}
    end
  end

  def season(_value) do
    {:error, :invalid_season}
  end

  @doc "Normalizes a bounded race round from an integer or decimal string."
  @spec round(term()) :: {:ok, round()} | {:error, :invalid_round}
  def round(value) when is_integer(value) and value in 1..@maximum_round do
    {:ok, value}
  end

  def round(value) when is_binary(value) do
    case Integer.parse(value) do
      {round, ""} -> round(round)
      _other -> {:error, :invalid_round}
    end
  end

  def round(_value) do
    {:error, :invalid_round}
  end

  @doc "Returns the finite set of session kinds understood by Vortex."
  @spec session_kinds() :: [session_kind()]
  def session_kinds do
    @session_kinds
  end

  @doc "Normalizes a session kind without converting arbitrary strings to atoms."
  @spec session_kind(term()) :: {:ok, session_kind()} | {:error, :invalid_session_kind}
  def session_kind(value) when value in @session_kinds do
    {:ok, value}
  end

  def session_kind(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case Map.fetch(@session_kind_strings, normalized) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :invalid_session_kind}
    end
  end

  def session_kind(_value) do
    {:error, :invalid_session_kind}
  end

  @doc """
  Produces bounded, single-line display text.

  Missing or blank input uses the `:fallback` option, which defaults to an em
  dash. The maximum length is 80 graphemes.
  """
  @spec display(term(), keyword()) :: String.t()
  def display(value, options \\ []) do
    fallback = Keyword.get(options, :fallback, "—")

    case normalize_display(value) do
      "" -> normalize_fallback(fallback)
      display -> display
    end
  end

  @doc """
  Builds a stable, bounded identifier using an allowlisted resource prefix.

  Unsafe or missing values use the `unknown` suffix. The returned value contains
  only lowercase ASCII letters, numbers, and hyphens.
  """
  @spec safe_ref(term(), :driver | :constructor | :session | :meeting | :result) :: String.t()
  def safe_ref(value, kind) do
    prefix = ref_prefix(kind)
    slug = normalize_ref(value)
    suffix = if slug == "", do: "unknown", else: slug

    prefix <> "-" <> suffix
  end

  @doc "Returns the neutral fallback used when no valid team color is available."
  @spec neutral_team_colour() :: String.t()
  def neutral_team_colour do
    @neutral_team_colour
  end

  @doc """
  Normalizes an exact six-character hexadecimal team color.

  Values are returned in uppercase without a leading hash. Invalid or missing
  values return the neutral team color.
  """
  @spec team_colour(term()) :: String.t()
  def team_colour(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9A-Fa-f]{6}\z/, value) do
      String.upcase(value)
    else
      @neutral_team_colour
    end
  end

  def team_colour(_value) do
    @neutral_team_colour
  end

  defp normalize_display(value) when is_binary(value) do
    value
    |> String.replace(~r/[\p{C}]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @maximum_display_length)
    |> String.trim()
  end

  defp normalize_display(value) when is_integer(value) or is_float(value) do
    value
    |> to_string()
    |> normalize_display()
  end

  defp normalize_display(_value) do
    ""
  end

  defp normalize_fallback(value) do
    case normalize_display(value) do
      "" -> "—"
      fallback -> fallback
    end
  end

  defp normalize_ref(value) when is_integer(value) and value >= 0 do
    Integer.to_string(value)
  end

  defp normalize_ref(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_]+/u, "-")
    |> String.replace(~r/[^a-z0-9-]/u, "")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, @maximum_ref_length)
    |> String.trim("-")
  end

  defp normalize_ref(_value) do
    ""
  end

  defp ref_prefix(:driver) do
    "driver"
  end

  defp ref_prefix(:constructor) do
    "constructor"
  end

  defp ref_prefix(:session) do
    "session"
  end

  defp ref_prefix(:meeting) do
    "meeting"
  end

  defp ref_prefix(:result) do
    "result"
  end
end
