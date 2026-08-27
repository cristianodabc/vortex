defmodule Vortex.F1.Cache.Server do
  @moduledoc """
  Owns bounded, node-local reference-data resources and in-flight loaders.

  HTTP work never runs in this GenServer. Loaders execute below the injected
  `Task.Supervisor`, and identical requests are coalesced before provider work
  begins. State is intentionally disposable and contains no raw provider data.
  """

  use GenServer

  alias Vortex.F1.Error
  alias Vortex.F1.Resource

  @default_max_entries 256
  @default_failure_retry_ms 1_000

  @type option ::
          {:name, GenServer.name()}
          | {:clock, (-> DateTime.t())}
          | {:task_supervisor, Supervisor.supervisor()}
          | {:observer, pid()}
          | {:max_entries, pos_integer()}
          | {:failure_retry_ms, pos_integer()}

  @doc "Starts the single owner for the configured cache boundary."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) do
    {name, init_options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_options, name: name)
  end

  @impl true
  def init(options) do
    state = %{
      entries: %{},
      inflight: %{},
      cooldowns: %{},
      access_sequence: 0,
      clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
      task_supervisor: Keyword.get(options, :task_supervisor, Vortex.F1.TaskSupervisor),
      observer: Keyword.get(options, :observer),
      max_entries: configured_max_entries(options),
      failure_retry_ms: configured_failure_retry_ms(options)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:fetch, key, ttl_ms, source, loader}, from, state) do
    now = state.clock.()
    state = clear_expired_cooldown(state, key, now)

    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        handle_cached_fetch(state, key, entry, ttl_ms, source, loader, now)

      :error ->
        handle_cold_fetch(state, key, ttl_ms, source, loader, from, now)
    end
  end

  @impl true
  def handle_info({:cache_loader_result, key, token, result}, state) do
    case Map.get(state.inflight, key) do
      %{token: ^token} = flight ->
        Process.demonitor(flight.monitor, [:flush])
        state = update_in(state.inflight, &Map.delete(&1, key))
        complete_load(state, key, flight, result)

      _obsolete ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case find_flight_by_monitor(state.inflight, monitor) do
      {key, flight} ->
        state = update_in(state.inflight, &Map.delete(&1, key))
        complete_load(state, key, flight, {:error, Error.new(:unavailable)})

      nil ->
        {:noreply, state}
    end
  end

  defp handle_cached_fetch(state, key, entry, ttl_ms, source, loader, now) do
    {state, entry} = touch_entry(state, key, entry)

    if fresh?(entry.resource, now) do
      notify(state, :hit, key)
      {:reply, {:ok, entry.resource}, state}
    else
      stale_resource = %{entry.resource | freshness: :stale}
      state = put_in(state.entries[key].resource, stale_resource)
      state = maybe_start_refresh(state, key, ttl_ms, source, loader, now)
      notify(state, :stale, key)
      {:reply, {:ok, stale_resource}, state}
    end
  end

  defp handle_cold_fetch(state, key, ttl_ms, source, loader, from, now) do
    cond do
      cooldown = active_cooldown(state, key, now) ->
        notify(state, :suppressed, key)
        {:reply, {:error, cooldown.error}, state}

      flight = Map.get(state.inflight, key) ->
        updated_flight = %{flight | waiters: [from | flight.waiters]}
        state = put_in(state.inflight[key], updated_flight)
        notify(state, :coalesced, key)
        {:noreply, state}

      true ->
        notify(state, :miss, key)

        case start_loader(state, key, ttl_ms, source, loader, :cold, [from]) do
          {:ok, state} ->
            {:noreply, state}

          {:error, state, error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  defp maybe_start_refresh(state, key, ttl_ms, source, loader, now) do
    cond do
      Map.has_key?(state.inflight, key) ->
        notify(state, :coalesced, key)
        state

      active_cooldown(state, key, now) ->
        notify(state, :suppressed, key)
        state

      true ->
        case start_loader(state, key, ttl_ms, source, loader, :refresh, []) do
          {:ok, state} -> state
          {:error, state, _error} -> state
        end
    end
  end

  defp start_loader(state, key, ttl_ms, source, loader, mode, waiters) do
    token = make_ref()
    owner = self()

    task = fn ->
      result = safe_load(loader)
      send(owner, {:cache_loader_result, key, token, result})
    end

    case Task.Supervisor.start_child(state.task_supervisor, task) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        flight = %{
          token: token,
          monitor: monitor,
          mode: mode,
          waiters: waiters,
          ttl_ms: ttl_ms,
          source: source
        }

        {:ok, put_in(state.inflight[key], flight)}

      {:error, _reason} ->
        error = Error.new(:unavailable, source: source)
        {:error, state, error}
    end
  end

  defp safe_load(loader) do
    case loader.() do
      {:ok, value} -> {:ok, value}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, Error.new(:schema)}
    end
  rescue
    _exception ->
      {:error, Error.new(:unavailable)}
  catch
    _kind, _reason ->
      {:error, Error.new(:unavailable)}
  end

  defp complete_load(state, key, flight, {:ok, value}) do
    now = state.clock.()
    version = next_version(state, key)

    resource = %Resource{
      value: value,
      source: flight.source,
      fetched_at: now,
      fresh_until: fresh_until(now, flight.ttl_ms),
      freshness: :fresh,
      stale_reason: nil,
      version: version
    }

    {state, access_sequence} = next_access(state)
    entry = %{resource: resource, accessed_at: access_sequence}

    state =
      state
      |> put_in([:entries, key], entry)
      |> update_in([:cooldowns], &Map.delete(&1, key))
      |> evict_excess(key)

    reply_waiters(flight.waiters, {:ok, resource})

    if flight.mode == :refresh do
      broadcast_refresh(key, resource.version)
    end

    notify(state, completion_event(flight.mode), key)
    {:noreply, state}
  end

  defp complete_load(state, key, flight, {:error, %Error{} = error}) do
    now = state.clock.()
    retry_ms = error.retry_after_ms || state.failure_retry_ms

    cooldown = %{
      until: DateTime.add(now, retry_ms, :millisecond),
      error: error
    }

    state = put_in(state.cooldowns[key], cooldown)
    state = preserve_stale_reason(state, key, error.message)

    reply_waiters(flight.waiters, {:error, error})

    if error.kind == :rate_limited do
      notify(state, :rate_limited, key)
    end

    if flight.mode == :refresh do
      notify(state, :refresh_failed, key)
    end

    {:noreply, state}
  end

  defp preserve_stale_reason(state, key, message) do
    case Map.get(state.entries, key) do
      nil ->
        state

      entry ->
        resource = %{entry.resource | freshness: :stale, stale_reason: message}
        put_in(state.entries[key].resource, resource)
    end
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, fn from ->
      GenServer.reply(from, reply)
    end)
  end

  defp touch_entry(state, key, entry) do
    {state, access_sequence} = next_access(state)
    entry = %{entry | accessed_at: access_sequence}
    {put_in(state.entries[key], entry), entry}
  end

  defp next_access(state) do
    access_sequence = state.access_sequence + 1
    {%{state | access_sequence: access_sequence}, access_sequence}
  end

  defp fresh?(%Resource{fresh_until: %DateTime{} = fresh_until}, now) do
    DateTime.compare(now, fresh_until) == :lt
  end

  defp fresh?(%Resource{fresh_until: nil, freshness: :fresh}, _now) do
    true
  end

  defp fresh?(_resource, _now) do
    false
  end

  defp next_version(state, key) do
    case Map.get(state.entries, key) do
      %{resource: %Resource{version: version}} -> version + 1
      _missing -> 1
    end
  end

  defp fresh_until(_now, :infinity) do
    nil
  end

  defp fresh_until(now, ttl_ms) do
    DateTime.add(now, ttl_ms, :millisecond)
  end

  defp evict_excess(state, protected_key) do
    if map_size(state.entries) > state.max_entries do
      {key, _entry} =
        state.entries
        |> Enum.reject(fn {key, _entry} -> key == protected_key end)
        |> Enum.min_by(fn {_key, entry} -> entry.accessed_at end)

      state = update_in(state.entries, &Map.delete(&1, key))
      notify(state, :evicted, key)
      state
    else
      state
    end
  end

  defp active_cooldown(state, key, now) do
    case Map.get(state.cooldowns, key) do
      %{until: until} = cooldown ->
        if DateTime.compare(now, until) == :lt, do: cooldown, else: nil

      nil ->
        nil
    end
  end

  defp clear_expired_cooldown(state, key, now) do
    if active_cooldown(state, key, now) do
      state
    else
      update_in(state.cooldowns, &Map.delete(&1, key))
    end
  end

  defp find_flight_by_monitor(inflight, monitor) do
    Enum.find(inflight, fn {_key, flight} ->
      flight.monitor == monitor
    end)
  end

  defp completion_event(:cold) do
    :load_completed
  end

  defp completion_event(:refresh) do
    :refresh_completed
  end

  defp notify(%{observer: observer}, event, key) when is_pid(observer) do
    emit_telemetry(event, key)
    send(observer, {:vortex_cache, event, key})
    :ok
  end

  defp notify(_state, event, key) do
    emit_telemetry(event, key)
    :ok
  end

  defp emit_telemetry(operation, key) do
    :telemetry.execute(
      [:vortex, :f1, :cache, :operation],
      %{count: 1},
      %{operation: operation, resource: resource_class(key)}
    )
  end

  defp resource_class({:schedule, _season}) do
    :schedule
  end

  defp resource_class({:results, _season, _round}) do
    :results
  end

  defp resource_class({:results, _season, _round, _kind}) do
    :results
  end

  defp resource_class({:driver_standings, _season}) do
    :driver_standings
  end

  defp resource_class({:constructor_standings, _season}) do
    :constructor_standings
  end

  defp resource_class(_key) do
    :other
  end

  defp configured_max_entries(options) do
    options
    |> Keyword.get(
      :max_entries,
      configured_value(:reference_cache_max_entries, @default_max_entries)
    )
    |> max(1)
  end

  defp configured_failure_retry_ms(options) do
    options
    |> Keyword.get(
      :failure_retry_ms,
      configured_value(:reference_cache_failure_retry_ms, @default_failure_retry_ms)
    )
    |> max(1)
  end

  defp configured_value(key, default) do
    :vortex
    |> Application.get_env(:f1, [])
    |> Keyword.get(key, default)
  end

  defp broadcast_refresh(key, version) do
    if Process.whereis(Vortex.PubSub) do
      Phoenix.PubSub.broadcast(
        Vortex.PubSub,
        "vortex:f1:reference",
        {Vortex.F1, :reference_refreshed, key, version}
      )
    end

    :ok
  end
end
