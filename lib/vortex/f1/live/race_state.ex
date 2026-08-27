defmodule Vortex.F1.Live.RaceState do
  @moduledoc """
  Serialized owner of the canonical, bounded current-race projection.

  `RaceState` commits pure reducer output before publishing version-only PubSub
  notifications. Subscribers treat PubSub as invalidation and reread through
  `current/1`; rows and provider payloads are never broadcast. A new session
  generation atomically discards every prior-session row and cursor.
  """

  use GenServer

  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.Reducer
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @default_topic "vortex:f1:current-race"
  @transitions %{
    inactive: [:connecting],
    connecting: [:live, :reconnecting, :resyncing, :rate_limited, :unavailable],
    live: [:stale, :reconnecting, :resyncing, :degraded, :unavailable],
    stale: [:connecting, :reconnecting, :resyncing, :degraded, :unavailable],
    rate_limited: [:connecting, :reconnecting, :degraded, :unavailable],
    reconnecting: [:connecting, :resyncing, :degraded, :unavailable],
    resyncing: [:live, :reconnecting, :degraded, :unavailable],
    degraded: [:connecting, :reconnecting, :resyncing, :unavailable],
    replay: [],
    unavailable: [:connecting, :reconnecting]
  }

  @type server :: GenServer.server()
  @type version :: {Types.generation(), Types.sequence()}

  @doc "Starts the supervised state owner with optional name, PubSub, and topic injection."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, options, name: name)
    else
      GenServer.start_link(__MODULE__, options)
    end
  end

  @doc "Returns the coherent current projection, or `:inactive` before a session begins."
  @spec current(server()) :: {:ok, RaceProjection.t()} | {:error, :inactive}
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  end

  @doc "Starts a new generation and atomically removes the prior session projection."
  @spec begin_session(server(), Session.t(), Types.source(), DateTime.t()) ::
          {:ok, version()}
  def begin_session(server \\ __MODULE__, session, source, captured_at) do
    GenServer.call(server, {:begin_session, session, source, captured_at})
  end

  @doc "Applies one coalesced event batch and returns its version and acceptance summary."
  @spec apply_batch(server(), [Event.t() | term()], DateTime.t()) ::
          {:ok, version(), Reducer.summary()}
  def apply_batch(server \\ __MODULE__, events, captured_at) do
    GenServer.call(server, {:apply_batch, events, captured_at})
  end

  @doc "Atomically replaces current state from a coherent provider reconciliation."
  @spec reconcile(server(), RaceProjection.t(), DateTime.t()) :: {:ok, version()}
  def reconcile(server \\ __MODULE__, candidate, captured_at) do
    GenServer.call(server, {:reconcile, candidate, captured_at})
  end

  @doc "Applies an allowlisted lifecycle transition while retaining last-known rows."
  @spec transition(server(), Types.status(), DateTime.t()) ::
          {:ok, version()} | {:error, :invalid_transition}
  def transition(server \\ __MODULE__, status, captured_at) do
    GenServer.call(server, {:transition, status, captured_at})
  end

  @impl true
  def init(options) do
    state = %{
      projection: %RaceProjection{},
      observer: Keyword.get(options, :observer),
      pubsub: Keyword.get(options, :pubsub, Vortex.PubSub),
      topic: Keyword.get(options, :topic, @default_topic)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, %{projection: %RaceProjection{session_key: nil}} = state) do
    observe_current_read(state)
    {:reply, {:error, :inactive}, state}
  end

  def handle_call(:current, _from, state) do
    observe_current_read(state)
    {:reply, {:ok, state.projection}, state}
  end

  def handle_call({:begin_session, session, source, captured_at}, _from, state) do
    projection = Reducer.begin_session(state.projection, session, source, captured_at)
    commit(state, projection, {:ok, version(projection)})
  end

  def handle_call({:apply_batch, events, captured_at}, _from, state) do
    {projection, summary} = Reducer.apply_batch(state.projection, events, captured_at)
    emit_batch(summary, state.projection.status)
    reply = {:ok, version(projection), summary}

    if version(projection) == version(state.projection) do
      {:reply, reply, state}
    else
      commit(state, projection, reply)
    end
  end

  def handle_call({:reconcile, candidate, captured_at}, _from, state) do
    projection = Reducer.reconcile(state.projection, candidate, captured_at)
    commit(state, projection, {:ok, version(projection)})
  end

  def handle_call({:transition, status, captured_at}, _from, state) do
    current_status = state.projection.status

    cond do
      status == current_status ->
        {:reply, {:ok, version(state.projection)}, state}

      valid_transition?(current_status, status) ->
        projection = transition_projection(state.projection, status, captured_at)
        commit(state, projection, {:ok, version(projection)})

      true ->
        {:reply, {:error, :invalid_transition}, state}
    end
  end

  @impl true
  def handle_continue({:broadcast, generation, sequence}, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      state.topic,
      {Vortex.F1, :current_race_updated, generation, sequence}
    )

    :telemetry.execute(
      [:vortex, :f1, :race_state, :publish],
      %{count: 1, generation: generation, sequence: sequence},
      projection_metadata(state.projection)
    )

    {:noreply, state}
  end

  defp commit(state, projection, reply) do
    {generation, sequence} = version(projection)
    emit_commit(projection, generation, sequence)
    next_state = %{state | projection: projection}
    {:reply, reply, next_state, {:continue, {:broadcast, generation, sequence}}}
  end

  defp version(projection) do
    {projection.generation, projection.sequence}
  end

  defp valid_transition?(current, target) do
    target in Map.get(@transitions, current, [])
  end

  defp transition_projection(projection, status, captured_at) do
    %{
      projection
      | status: status,
        sequence: projection.sequence + 1,
        captured_at: captured_at,
        stale_since: stale_since(projection, status, captured_at)
    }
  end

  defp stale_since(_projection, :live, _captured_at) do
    nil
  end

  defp stale_since(projection, status, captured_at)
       when status in [:stale, :reconnecting, :resyncing, :degraded] do
    projection.stale_since || captured_at
  end

  defp stale_since(projection, _status, _captured_at) do
    projection.stale_since
  end

  defp observe_current_read(%{observer: observer}) when is_pid(observer) do
    send(observer, {:vortex_race_state, :current_read})
  end

  defp observe_current_read(_state) do
    :ok
  end

  defp emit_batch(summary, status) do
    :telemetry.execute(
      [:vortex, :f1, :race_state, :batch],
      Map.put(summary, :count, 1),
      %{status: status}
    )
  end

  defp emit_commit(projection, generation, sequence) do
    :telemetry.execute(
      [:vortex, :f1, :race_state, :commit],
      %{
        count: 1,
        generation: generation,
        sequence: sequence,
        mailbox_length: mailbox_length()
      },
      projection_metadata(projection)
    )
  end

  defp projection_metadata(projection) do
    %{source: projection.source, status: projection.status}
  end

  defp mailbox_length do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, length} -> length
      _missing -> 0
    end
  end
end
