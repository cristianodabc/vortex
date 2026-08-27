defmodule Vortex.F1.Live.Event do
  @moduledoc """
  A normalized, provider-independent change to the current race projection.

  Provider adapters must select one of the fixed topic atoms and normalize all
  values before constructing an event. Raw provider maps never enter reducers,
  process mailboxes, LiveView assigns, logs, or Telemetry metadata.
  """

  alias Vortex.F1.Driver
  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow
  alias Vortex.F1.Types

  @topics [:driver, :position, :interval, :lap, :stint, :pit, :session]
  @topic_fields %{
    driver: [:driver, :team_colour],
    position: [:position, :status],
    interval: [:gap, :interval],
    lap: [:last_lap, :best_lap],
    stint: [:tyre, :tyre_age],
    pit: [:pit_state, :status],
    session: [:session]
  }

  @type topic :: :driver | :position | :interval | :lap | :stint | :pit | :session

  @typedoc "A fixed set of normalized changes accepted for one topic."
  @type changes :: %{
          optional(:driver) => Driver.t(),
          optional(:team_colour) => String.t(),
          optional(:position) => pos_integer() | nil,
          optional(:status) => String.t(),
          optional(:gap) => String.t(),
          optional(:interval) => String.t(),
          optional(:last_lap) => String.t(),
          optional(:best_lap) => String.t(),
          optional(:tyre) => TimingRow.tyre(),
          optional(:tyre_age) => non_neg_integer() | nil,
          optional(:pit_state) => TimingRow.pit_state(),
          optional(:session) => Session.t()
        }

  @typedoc "One normalized provider update with a per-topic logical cursor."
  @type t :: %__MODULE__{
          id: non_neg_integer() | nil,
          session_key: Types.session_key() | nil,
          topic: topic() | atom() | nil,
          key: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          changes: changes() | map()
        }

  defstruct id: nil,
            session_key: nil,
            topic: nil,
            key: nil,
            occurred_at: nil,
            changes: %{}

  @doc "Returns the fixed normalized topics accepted by the reducer."
  @spec topics() :: [topic()]
  def topics do
    @topics
  end

  @doc "Returns whether an event topic is one of the application-owned atoms."
  @spec known_topic?(term()) :: boolean()
  def known_topic?(topic) do
    topic in @topics
  end

  @doc "Validates the normalized shape without coercing or creating atoms."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = event) do
    valid_id?(event.id) and valid_session_key?(event.session_key) and
      valid_key?(event.key) and valid_time?(event.occurred_at) and
      valid_changes?(event.topic, event.changes)
  end

  def valid?(_event) do
    false
  end

  defp valid_id?(id) do
    is_integer(id) and id >= 0
  end

  defp valid_session_key?(key) do
    (is_integer(key) and key >= 0) or (is_binary(key) and key != "")
  end

  defp valid_key?(key) do
    is_binary(key) and key != "" and byte_size(key) <= 96
  end

  defp valid_time?(nil) do
    true
  end

  defp valid_time?(%DateTime{}) do
    true
  end

  defp valid_time?(_time) do
    false
  end

  defp valid_changes?(topic, changes) when is_map(changes) do
    case Map.fetch(@topic_fields, topic) do
      {:ok, allowed_fields} ->
        keys = Map.keys(changes)
        keys != [] and Enum.all?(keys, &(&1 in allowed_fields))

      :error ->
        false
    end
  end

  defp valid_changes?(_topic, _changes) do
    false
  end
end
