defmodule Vortex.F1.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vortex.F1.Cache
  alias Vortex.F1.Cache.Server
  alias Vortex.F1.Jolpica.Client
  alias Vortex.F1.Live.Event
  alias Vortex.F1.Live.RaceState
  alias Vortex.F1.Live.ReplayStore
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.Session

  @provider_event [:vortex, :f1, :provider, :request]
  @cache_event [:vortex, :f1, :cache, :operation]
  @race_batch_event [:vortex, :f1, :race_state, :batch]
  @race_commit_event [:vortex, :f1, :race_state, :commit]
  @race_publish_event [:vortex, :f1, :race_state, :publish]
  @replay_store_event [:vortex, :f1, :replay_store, :operation]

  setup do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          @provider_event,
          @cache_event,
          @race_batch_event,
          @race_commit_event,
          @race_publish_event,
          @replay_store_event
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "provider telemetry reports duration and result class without request data" do
    secret = "credential-and-provider-body-must-stay-private"

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "2")
      |> Plug.Conn.send_resp(429, secret)
    end

    log =
      capture_log(fn ->
        assert {:error, error} =
                 Client.get("private/#{secret}",
                   operation: :schedule,
                   request_options: [plug: plug, retry: false]
                 )

        refute inspect(error) =~ secret
      end)

    refute log =~ secret

    assert_receive {:telemetry, @provider_event, %{duration: duration}, metadata}
    assert is_integer(duration)
    assert duration >= 0

    assert metadata == %{
             provider: :jolpica,
             operation: :schedule,
             result: :rate_limited,
             rate_limited: true
           }

    refute inspect(metadata) =~ secret
  end

  test "cache telemetry classifies operations without exposing exact keys" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    cache =
      start_supervised!(
        {Server,
         name: nil,
         task_supervisor: task_supervisor,
         max_entries: 2,
         clock: fn -> ~U[2026-08-27 12:00:00Z] end}
      )

    secret = "secret-season-token"
    key = {:schedule, secret}

    assert {:ok, _resource} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :fixture], fn ->
               {:ok, []}
             end)

    assert_receive {:telemetry, @cache_event, %{count: 1},
                    %{operation: :miss, resource: :schedule}}

    assert_receive {:telemetry, @cache_event, %{count: 1},
                    %{operation: :load_completed, resource: :schedule}}

    assert {:ok, _resource} =
             Cache.fetch(cache, key, [ttl_ms: 1_000, source: :fixture], fn ->
               flunk("fresh cache hit should not load")
             end)

    assert_receive {:telemetry, @cache_event, %{count: 1},
                    %{operation: :hit, resource: :schedule} = metadata}

    refute inspect(metadata) =~ secret
  end

  test "race-state telemetry reports bounded counts and versions without payloads" do
    topic = "telemetry-race-#{System.unique_integer([:positive])}"
    server = start_supervised!({RaceState, name: nil, topic: topic})
    session = %Session{id: "session-private", key: 101, kind: :race, name: "Private"}

    assert {:ok, {1, 0}} = RaceState.begin_session(server, session, :fixture, now())

    assert_receive {:telemetry, @race_commit_event,
                    %{count: 1, generation: 1, sequence: 0, mailbox_length: mailbox},
                    %{source: :fixture, status: :connecting}}

    assert is_integer(mailbox)

    event = %Event{
      id: 1,
      session_key: 101,
      topic: :position,
      key: "private-driver-key",
      occurred_at: now(),
      changes: %{position: 1}
    }

    assert {:ok, {1, 1}, _summary} = RaceState.apply_batch(server, [event], now())

    assert_receive {:telemetry, @race_batch_event,
                    %{accepted: 1, coalesced: 0, duplicate: 0, malformed: 0, older: 0},
                    %{status: :connecting}}

    assert_receive {:telemetry, @race_publish_event, %{count: 1, generation: 1, sequence: 1},
                    %{source: :fixture, status: :connecting} = metadata}

    refute inspect(metadata) =~ "private-driver-key"
  end

  test "replay-store telemetry reports cache work without session keys" do
    task_supervisor = start_supervised!({Task.Supervisor, name: nil})
    store = start_supervised!({ReplayStore, name: nil, task_supervisor: task_supervisor})
    secret_key = "secret-provider-session"

    loader = fn ->
      session = %Session{id: "session-safe", key: 101, kind: :race, name: "Race"}
      {:ok, ReplayTimeline.new(session, :fixture, [])}
    end

    assert {:ok, _timeline} = ReplayStore.open(store, secret_key, loader)

    assert_receive {:telemetry, @replay_store_event, %{count: 1}, %{operation: :miss}}
    assert_receive {:telemetry, @replay_store_event, %{count: 1}, %{operation: :load_completed}}

    assert {:ok, _timeline} = ReplayStore.open(store, secret_key, fn -> flunk("cache miss") end)
    assert_receive {:telemetry, @replay_store_event, %{count: 1}, %{operation: :hit} = metadata}
    refute inspect(metadata) =~ secret_key
  end

  defp now do
    ~U[2026-08-27 12:00:00Z]
  end
end
