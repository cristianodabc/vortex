defmodule Vortex.F1.Live.ReplayStore do
  @moduledoc """
  Bounded, expiring owner of shared immutable replay timelines.

  Concurrent opens for the same session share one supervised loader task.
  Provider work never runs in the GenServer, and completed timelines are capped
  by event count and least-recently-used capacity before entering memory.
  """

  use GenServer

  alias Vortex.F1.Live.ReplayTimeline

  @default_ttl_ms :timer.minutes(30)
  @default_max_timelines 3
  @default_max_events 50_000

  @type server :: GenServer.server()
  @type session_key :: non_neg_integer() | String.t()
  @type loader :: (-> {:ok, ReplayTimeline.t()} | {:error, term()})

  @doc "Starts a replay store with injectable clock, task supervisor, and memory bounds."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, options, name: name)
    else
      GenServer.start_link(__MODULE__, options)
    end
  end

  @doc "Returns a cached timeline or coalesces one supervised loader invocation."
  @spec open(server(), session_key(), loader()) ::
          {:ok, ReplayTimeline.t()} | {:error, term()}
  def open(server \\ __MODULE__, session_key, loader) when is_function(loader, 0) do
    GenServer.call(server, {:open, session_key, loader}, :infinity)
  end

  @doc "Removes expired timelines immediately and returns the number evicted."
  @spec evict_expired(server()) :: non_neg_integer()
  def evict_expired(server \\ __MODULE__) do
    GenServer.call(server, :evict_expired)
  end

  @impl true
  def init(options) do
    state = %{
      clock: Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end),
      entries: %{},
      loads: %{},
      max_events: Keyword.get(options, :max_events, @default_max_events),
      max_timelines: Keyword.get(options, :max_timelines, @default_max_timelines),
      task_supervisor: Keyword.get(options, :task_supervisor, Vortex.F1.TaskSupervisor),
      ttl_ms: Keyword.get(options, :ttl_ms, @default_ttl_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:open, session_key, loader}, from, state) do
    now = state.clock.()
    state = prune_expired_with_telemetry(state, now)

    case Map.fetch(state.entries, session_key) do
      {:ok, entry} ->
        emit_operation(:hit)
        entries = Map.put(state.entries, session_key, %{entry | touched_at: now})
        {:reply, {:ok, entry.timeline}, %{state | entries: entries}}

      :error ->
        queue_or_start_load(state, session_key, loader, from)
    end
  end

  def handle_call(:evict_expired, _from, state) do
    now = state.clock.()
    next_state = prune_expired(state, now)
    evicted = map_size(state.entries) - map_size(next_state.entries)
    emit_evictions(evicted)
    {:reply, evicted, next_state}
  end

  @impl true
  def handle_info({reference, {session_key, result}}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])

    case Map.pop(state.loads, session_key) do
      {nil, _loads} ->
        {:noreply, state}

      {%{reference: ^reference, waiters: waiters}, loads} ->
        {reply, entries} = complete_load(state, session_key, result)
        Enum.each(waiters, &GenServer.reply(&1, reply))
        {:noreply, %{state | entries: entries, loads: loads}}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case load_by_reference(state.loads, reference) do
      nil ->
        {:noreply, state}

      {session_key, waiters} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, {:loader_exit, reason}}))
        {:noreply, %{state | loads: Map.delete(state.loads, session_key)}}
    end
  end

  defp queue_or_start_load(state, session_key, loader, from) do
    case Map.fetch(state.loads, session_key) do
      {:ok, load} ->
        emit_operation(:coalesced)
        loads = Map.put(state.loads, session_key, %{load | waiters: [from | load.waiters]})
        {:noreply, %{state | loads: loads}}

      :error ->
        emit_operation(:miss)

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            {session_key, loader.()}
          end)

        load = %{reference: task.ref, waiters: [from]}
        {:noreply, %{state | loads: Map.put(state.loads, session_key, load)}}
    end
  end

  defp complete_load(state, session_key, {:ok, %ReplayTimeline{} = timeline}) do
    now = state.clock.()
    bounded = ReplayTimeline.limit(timeline, state.max_events)
    entry = %{timeline: bounded, inserted_at: now, touched_at: now}

    before_capacity = map_size(state.entries) + 1

    entries =
      state.entries
      |> Map.put(session_key, entry)
      |> enforce_capacity(state.max_timelines)

    emit_operation(:load_completed)
    emit_evictions(max(before_capacity - map_size(entries), 0))

    {{:ok, bounded}, entries}
  end

  defp complete_load(state, _session_key, {:error, reason}) do
    emit_operation(:load_failed)
    {{:error, reason}, state.entries}
  end

  defp complete_load(state, _session_key, _invalid) do
    emit_operation(:load_failed)
    {{:error, :malformed_timeline}, state.entries}
  end

  defp prune_expired(state, now) do
    entries =
      Map.reject(state.entries, fn {_key, entry} ->
        now - entry.inserted_at >= state.ttl_ms
      end)

    %{state | entries: entries}
  end

  defp prune_expired_with_telemetry(state, now) do
    next_state = prune_expired(state, now)
    emit_evictions(map_size(state.entries) - map_size(next_state.entries))
    next_state
  end

  defp enforce_capacity(entries, maximum) when map_size(entries) <= maximum do
    entries
  end

  defp enforce_capacity(entries, maximum) do
    {oldest_key, _entry} = Enum.min_by(entries, fn {_key, entry} -> entry.touched_at end)
    enforce_capacity(Map.delete(entries, oldest_key), maximum)
  end

  defp load_by_reference(loads, reference) do
    Enum.find_value(loads, fn {session_key, load} ->
      if load.reference == reference do
        {session_key, load.waiters}
      end
    end)
  end

  defp emit_operation(operation) do
    :telemetry.execute(
      [:vortex, :f1, :replay_store, :operation],
      %{count: 1},
      %{operation: operation}
    )
  end

  defp emit_evictions(count) when count > 0 do
    :telemetry.execute(
      [:vortex, :f1, :replay_store, :operation],
      %{count: count},
      %{operation: :eviction}
    )
  end

  defp emit_evictions(_count) do
    :ok
  end
end
