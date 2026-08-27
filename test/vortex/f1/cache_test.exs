defmodule Vortex.F1.CacheTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Cache
  alias Vortex.F1.Cache.Server
  alias Vortex.F1.Error
  alias Vortex.F1.Resource

  setup do
    clock = start_supervised!({Agent, fn -> ~U[2026-08-27 12:00:00Z] end})
    task_supervisor = start_supervised!({Task.Supervisor, []})

    cache =
      start_supervised!(
        {Server,
         clock: fn -> Agent.get(clock, & &1) end,
         name: nil,
         task_supervisor: task_supervisor,
         observer: self(),
         max_entries: 2,
         failure_retry_ms: 1_000}
      )

    %{cache: cache, clock: clock}
  end

  test "returns fresh hits without running another loader", %{cache: cache} do
    assert {:ok, %Resource{value: [:initial], freshness: :fresh, version: 1}} =
             Cache.fetch(cache, {:schedule, 2026}, [ttl_ms: 1_000, source: :jolpica], fn ->
               {:ok, [:initial]}
             end)

    assert {:ok, %Resource{value: [:initial], freshness: :fresh, version: 1}} =
             Cache.fetch(cache, {:schedule, 2026}, [ttl_ms: 1_000, source: :jolpica], fn ->
               flunk("fresh hits must not invoke the loader")
             end)
  end

  test "coalesces concurrent cold loads behind one supervised task", %{cache: cache} do
    parent = self()

    loader = fn ->
      send(parent, {:loader_started, self()})

      receive do
        :release -> {:ok, [:shared]}
      end
    end

    first =
      Task.async(fn ->
        Cache.fetch(cache, {:results, 2026, 1}, [ttl_ms: 1_000, source: :jolpica], loader)
      end)

    assert_receive {:loader_started, loader_pid}

    second =
      Task.async(fn ->
        Cache.fetch(cache, {:results, 2026, 1}, [ttl_ms: 1_000, source: :jolpica], loader)
      end)

    assert_receive {:vortex_cache, :coalesced, {:results, 2026, 1}}
    refute_receive {:loader_started, _another_loader}

    send(loader_pid, :release)

    assert {:ok, %Resource{value: [:shared], version: 1}} = Task.await(first)
    assert {:ok, %Resource{value: [:shared], version: 1}} = Task.await(second)
  end

  test "serves stale data while one background revalidation runs", %{
    cache: cache,
    clock: clock
  } do
    key = {:driver_standings, 2026}

    assert {:ok, %Resource{value: [:old]}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               {:ok, [:old]}
             end)

    advance(clock, 1_001)
    parent = self()

    reloader = fn ->
      send(parent, {:refresh_started, self()})

      receive do
        :release -> {:ok, [:new]}
      end
    end

    assert {:ok, %Resource{value: [:old], freshness: :stale, version: 1}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], reloader)

    assert_receive {:refresh_started, refresh_pid}

    assert {:ok, %Resource{value: [:old], freshness: :stale, version: 1}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], reloader)

    assert_receive {:vortex_cache, :coalesced, ^key}
    refute_receive {:refresh_started, _another_refresh}

    send(refresh_pid, :release)
    assert_receive {:vortex_cache, :refresh_completed, ^key}

    assert {:ok, %Resource{value: [:new], freshness: :fresh, version: 2}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               flunk("the completed refresh should be fresh")
             end)
  end

  test "preserves last-known data and records a safe reason after refresh failure", %{
    cache: cache,
    clock: clock
  } do
    key = {:constructor_standings, 2026}

    assert {:ok, %Resource{value: [:known]}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               {:ok, [:known]}
             end)

    advance(clock, 1_001)

    assert {:ok, %Resource{value: [:known], freshness: :stale}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               {:error, Error.new(:upstream, source: :jolpica)}
             end)

    assert_receive {:vortex_cache, :refresh_failed, ^key}

    assert {:ok, %Resource{value: [:known], freshness: :stale} = resource} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               flunk("ordinary refresh failures should observe a short retry cooldown")
             end)

    assert resource.stale_reason == "The data source returned an unexpected response."
  end

  test "evicts the least recently used entry at the configured bound", %{cache: cache} do
    assert {:ok, %Resource{}} = load(cache, :a, :a)
    assert {:ok, %Resource{}} = load(cache, :b, :b)
    assert {:ok, %Resource{value: :a}} = load(cache, :a, :unused)
    assert {:ok, %Resource{}} = load(cache, :c, :c)
    assert_receive {:vortex_cache, :evicted, :b}

    parent = self()

    assert {:ok, %Resource{value: :b_reloaded}} =
             Cache.fetch(cache, :b, [ttl_ms: 1_000, source: :jolpica], fn ->
               send(parent, :b_loader_ran)
               {:ok, :b_reloaded}
             end)

    assert_receive :b_loader_ran
  end

  test "suppresses cold loads until a provider rate limit expires", %{
    cache: cache,
    clock: clock
  } do
    key = {:schedule, 2027}

    assert {:error, %Error{kind: :rate_limited, retry_after_ms: 2_000}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               {:error, Error.new(:rate_limited, source: :jolpica, retry_after_ms: 2_000)}
             end)

    assert_receive {:vortex_cache, :rate_limited, ^key}

    assert {:error, %Error{kind: :rate_limited}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               flunk("rate-limited keys must not invoke the provider")
             end)

    advance(clock, 2_001)

    assert {:ok, %Resource{value: [:recovered]}} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
               {:ok, [:recovered]}
             end)
  end

  defp load(cache, key, value) do
    Cache.fetch(cache, key, [ttl_ms: 1_000, source: :jolpica], fn ->
      {:ok, value}
    end)
  end

  defp advance(clock, milliseconds) do
    Agent.update(clock, &DateTime.add(&1, milliseconds, :millisecond))
  end
end
