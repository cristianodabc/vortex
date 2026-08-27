defmodule VortexWeb.LiveTimingLive do
  @moduledoc """
  Presents shared current timing or isolated historical playback.

  Live mode subscribes before its initial context read and treats PubSub as
  version invalidation. Replay mode opens one bounded immutable timeline shared
  by viewers, while cursor, timer generation, speed, and rendered projection
  stay inside each LiveView. Replay never reads or mutates canonical race state.
  """

  use VortexWeb, :live_view

  import VortexWeb.DashboardComponents
  import VortexWeb.LiveTimingComponents

  alias Vortex.F1
  alias Vortex.F1.Error
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Types

  @replay_speeds [0.5, 1.0, 2.0, 4.0]
  @minimum_replay_season 2023

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Live timing")
     |> assign(:theme, "system")
     |> assign(:mode, :live)
     |> assign(:timing_state, :inactive)
     |> assign(:timing_message, "No active session")
     |> assign(:session_name, "Current session")
     |> assign(:source_label, "Waiting for feed")
     |> assign(:generation, 0)
     |> assign(:sequence, 0)
     |> assign(:replay_season, Date.utc_today().year)
     |> assign(:replay_session_key, nil)
     |> assign(:replay_sessions, [])
     |> assign(:replay_timeline, nil)
     |> assign(:replay_cursor, 0)
     |> assign(:replay_playing, false)
     |> assign(:replay_speed, 1.0)
     |> assign(:replay_speeds, @replay_speeds)
     |> assign(:minimum_replay_season, @minimum_replay_season)
     |> assign(:timer_generation, 0)
     |> stream_configure(:timing_rows, dom_id: & &1.id)
     |> stream(:timing_rows, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case normalize_mode_params(params) do
      {:ok, :live, _season, _session_key} ->
        {:noreply, activate_live(socket)}

      {:ok, :replay, season, session_key} ->
        {:noreply, activate_replay(socket, season, session_key)}

      :error ->
        {:noreply, push_patch(socket, to: ~p"/live-timing")}
    end
  end

  @impl true
  def handle_event("select_replay", params, socket) do
    season = Map.get(params, "season", to_string(socket.assigns.replay_season))
    session_key = Map.get(params, "session", "")

    destination =
      with {:ok, normalized_season} <- replay_season(season),
           {:ok, normalized_key} <- optional_session_key(session_key) do
        replay_path(normalized_season, normalized_key)
      else
        _invalid -> replay_path(Date.utc_today().year, nil)
      end

    {:noreply, push_patch(socket, to: destination)}
  end

  def handle_event("replay_toggle", _params, %{assigns: %{replay_timeline: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("replay_toggle", _params, %{assigns: %{replay_playing: true}} = socket) do
    {:noreply, pause_replay(socket)}
  end

  def handle_event("replay_toggle", _params, socket) do
    if socket.assigns.replay_cursor < socket.assigns.replay_timeline.event_count do
      {:noreply, play_replay(socket)}
    else
      {:noreply, socket |> apply_replay_cursor(0) |> play_replay()}
    end
  end

  def handle_event("replay_step", _params, socket) do
    cursor = min(socket.assigns.replay_cursor + 1, replay_event_count(socket))
    {:noreply, socket |> pause_replay() |> apply_replay_cursor(cursor)}
  end

  def handle_event("replay_restart", _params, socket) do
    {:noreply, socket |> pause_replay() |> apply_replay_cursor(0)}
  end

  def handle_event("replay_scrub", %{"cursor" => cursor}, socket) do
    case Integer.parse(cursor) do
      {parsed, ""} ->
        bounded = parsed |> max(0) |> min(replay_event_count(socket))
        {:noreply, socket |> pause_replay() |> apply_replay_cursor(bounded)}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("replay_speed", %{"speed" => speed}, socket) do
    case parse_replay_speed(speed) do
      {:ok, normalized} -> {:noreply, assign(socket, :replay_speed, normalized)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(
        {:replay_sessions, season},
        {:ok, {:ok, sessions}},
        %{assigns: %{mode: :replay, replay_season: season}} = socket
      ) do
    socket = assign(socket, :replay_sessions, sessions)

    case socket.assigns.replay_session_key do
      nil ->
        {:noreply, socket}

      session_key ->
        if Enum.any?(sessions, &(&1.key == session_key)) do
          {:noreply, maybe_start_timeline(socket, session_key)}
        else
          {:noreply, push_patch(socket, to: replay_path(season, nil))}
        end
    end
  end

  def handle_async(
        {:replay_timeline, session_key},
        {:ok, {:ok, %ReplayTimeline{} = timeline}},
        %{assigns: %{mode: :replay, replay_session_key: session_key}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:replay_timeline, timeline)
     |> assign(:replay_cursor, 0)
     |> assign(:replay_playing, false)
     |> assign(:timing_state, :replay)
     |> assign(:timing_message, "Replay")
     |> assign(:session_name, timeline.session.name)
     |> assign(:source_label, source_label(timeline.source))
     |> assign(:generation, 1)
     |> assign(:sequence, 0)
     |> stream(:timing_rows, [], reset: true)}
  end

  def handle_async(
        {:replay_timeline, session_key},
        {:ok, {:error, %Error{} = error}},
        %{assigns: %{mode: :replay, replay_session_key: session_key}} = socket
      ) do
    {:noreply, assign_replay_error(socket, error)}
  end

  def handle_async(
        {:replay_timeline, session_key},
        {:exit, _reason},
        %{assigns: %{mode: :replay, replay_session_key: session_key}} = socket
      ) do
    {:noreply, assign_replay_error(socket, Error.new(:unavailable))}
  end

  def handle_async({:replay_sessions, _season}, _result, socket) do
    {:noreply, socket}
  end

  def handle_async({:replay_timeline, _session_key}, _result, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {F1, :current_race_updated, generation, sequence},
        %{assigns: %{mode: :live}} = socket
      ) do
    if newer_version?(socket, generation, sequence) do
      {:noreply, read_current_race(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:replay_tick, generation},
        %{assigns: %{mode: :replay, replay_playing: true, timer_generation: generation}} = socket
      ) do
    cursor = min(socket.assigns.replay_cursor + 1, replay_event_count(socket))
    emit_replay_tick(socket, cursor)
    socket = apply_replay_cursor(socket, cursor)

    if cursor == replay_event_count(socket) do
      {:noreply, pause_replay(socket)}
    else
      {:noreply, schedule_replay_tick(socket)}
    end
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.dashboard_shell active_page={:live_timing} theme={@theme}>
        <:filters>
          <div class="timing-filter-row">
            <nav id="timing-mode-tabs" class="session-tabs" aria-label="Timing mode">
              <.link
                id="timing-mode-live"
                patch={~p"/live-timing"}
                aria-current={mode_current(@mode, :live)}
              >
                Live
              </.link>
              <.link
                id="timing-mode-replay"
                patch={replay_path(@replay_season, @replay_session_key)}
                aria-current={mode_current(@mode, :replay)}
              >
                Replay
              </.link>
            </nav>

            <form
              :if={@mode == :replay}
              id="replay-filters"
              class="compact-filters"
              phx-change="select_replay"
            >
              <label for="replay-season">Season</label>
              <input
                id="replay-season"
                type="number"
                name="season"
                min={@minimum_replay_season}
                max={Date.utc_today().year}
                value={@replay_season}
              />
              <label for="replay-session">Race</label>
              <select id="replay-session" name="session">
                <option value="" selected={is_nil(@replay_session_key)}>Select race</option>
                <option
                  :for={session <- @replay_sessions}
                  value={session.key}
                  selected={session.key == @replay_session_key}
                >
                  {session.name}
                </option>
              </select>
            </form>

            <div class="timing-status-rail" aria-label="Timing source">
              <p class="filter-context">{@session_name}</p>
              <span class="timing-source">{@source_label}</span>
              <span class="timing-version">v{@generation}.{@sequence}</span>
            </div>
          </div>
        </:filters>

        <section
          id="live-timing-page"
          class={["dashboard-page", (@mode == :replay and @replay_timeline) && "has-replay-controls"]}
          aria-labelledby="live-timing-title"
        >
          <header id="live-timing-header" class="page-header timing-page-header">
            <div>
              <p class="page-kicker">
                {if @mode == :replay, do: "Historical playback", else: "Timing tower"}
              </p>
              <h1 id="live-timing-title">Live timing</h1>
            </div>
            <p
              id="live-timing-state"
              class="state-label"
              data-state={@timing_state}
              role="status"
              aria-live="polite"
            >
              {@timing_message}
            </p>
          </header>

          <div
            :if={@mode == :replay and @replay_timeline}
            id="replay-controls"
            class="replay-controls"
          >
            <div class="replay-buttons" role="group" aria-label="Replay transport">
              <button
                id="replay-restart"
                type="button"
                phx-click="replay_restart"
                aria-label="Restart replay"
              >
                <.icon name="hero-backward" />
              </button>
              <button id="replay-toggle" type="button" phx-click="replay_toggle">
                <.icon name={if @replay_playing, do: "hero-pause", else: "hero-play"} />
                <span>{if @replay_playing, do: "Pause", else: "Play"}</span>
              </button>
              <button
                id="replay-step"
                type="button"
                phx-click="replay_step"
                aria-label="Step one event"
              >
                <.icon name="hero-forward" />
              </button>
            </div>

            <form id="replay-scrubber" class="replay-scrubber" phx-change="replay_scrub">
              <label for="replay-cursor" class="sr-only">Replay position</label>
              <input
                id="replay-cursor"
                type="range"
                name="cursor"
                min="0"
                max={@replay_timeline.event_count}
                value={@replay_cursor}
              />
            </form>

            <p id="replay-progress" class="replay-progress">
              {@replay_cursor} / {@replay_timeline.event_count} events
            </p>

            <label for="replay-speed" class="sr-only">Playback speed</label>
            <select id="replay-speed" name="speed" phx-change="replay_speed">
              <option
                :for={speed <- @replay_speeds}
                value={speed_value(speed)}
                selected={speed == @replay_speed}
              >
                {speed_label(speed)}
              </option>
            </select>
          </div>

          <.timing_table rows={@streams.timing_rows} />
        </section>
      </.dashboard_shell>
    </Layouts.app>
    """
  end

  defp activate_live(socket) do
    socket =
      socket
      |> pause_replay()
      |> assign(:mode, :live)
      |> assign(:replay_timeline, nil)
      |> assign(:replay_cursor, 0)

    if connected?(socket) do
      :ok = F1.subscribe_to_current_race()
      read_current_race(socket)
    else
      assign_empty_state(socket, :inactive)
    end
  end

  defp activate_replay(socket, season, session_key) do
    socket =
      socket
      |> pause_replay()
      |> assign(:mode, :replay)
      |> assign(:replay_season, season)
      |> assign(:replay_session_key, session_key)
      |> assign(:replay_sessions, [])
      |> assign(:replay_timeline, nil)
      |> assign(:replay_cursor, 0)
      |> assign(:timing_state, :replay)
      |> assign(:timing_message, replay_loading_message(session_key))
      |> assign(:session_name, "Historical race")
      |> assign(:source_label, "OpenF1 historical")
      |> assign(:generation, 0)
      |> assign(:sequence, 0)
      |> stream(:timing_rows, [], reset: true)

    if connected?(socket) do
      start_async(socket, {:replay_sessions, season}, fn -> F1.replay_sessions(season) end)
    else
      socket
    end
  end

  defp maybe_start_timeline(socket, nil) do
    socket
  end

  defp maybe_start_timeline(socket, session_key) do
    start_async(socket, {:replay_timeline, session_key}, fn -> F1.open_replay(session_key) end)
  end

  defp read_current_race(socket) do
    case F1.current_race() do
      {:ok, %RaceProjection{} = projection} -> assign_projection(socket, projection)
      {:error, :inactive} -> assign_empty_state(socket, :inactive)
      {:error, :unavailable} -> assign_empty_state(socket, :unavailable)
    end
  end

  defp assign_projection(socket, projection) do
    socket
    |> assign(:timing_state, projection.status)
    |> assign(:timing_message, state_label(projection.status))
    |> assign(:session_name, session_name(projection))
    |> assign(:source_label, source_label(projection.source))
    |> assign(:generation, projection.generation)
    |> assign(:sequence, projection.sequence)
    |> stream(:timing_rows, projection.rows, reset: true)
  end

  defp assign_empty_state(socket, status) do
    socket
    |> assign(:timing_state, status)
    |> assign(:timing_message, state_label(status))
    |> assign(:session_name, "Current session")
    |> assign(:source_label, "Waiting for feed")
    |> assign(:generation, 0)
    |> assign(:sequence, 0)
    |> stream(:timing_rows, [], reset: true)
  end

  defp assign_replay_error(socket, error) do
    socket
    |> assign(:timing_state, error_state(error))
    |> assign(:timing_message, error.message)
    |> assign(:replay_timeline, nil)
    |> assign(:replay_playing, false)
    |> stream(:timing_rows, [], reset: true)
  end

  defp apply_replay_cursor(%{assigns: %{replay_timeline: nil}} = socket, _cursor) do
    socket
  end

  defp apply_replay_cursor(socket, cursor) do
    projection = ReplayTimeline.project(socket.assigns.replay_timeline, cursor)

    socket
    |> assign(:replay_cursor, cursor)
    |> assign(:timing_state, :replay)
    |> assign(:timing_message, "Replay")
    |> assign(:generation, projection.generation)
    |> assign(:sequence, cursor)
    |> stream(:timing_rows, projection.rows, reset: true)
  end

  defp play_replay(socket) do
    socket
    |> assign(:replay_playing, true)
    |> assign(:timer_generation, socket.assigns.timer_generation + 1)
    |> schedule_replay_tick()
  end

  defp pause_replay(socket) do
    socket
    |> assign(:replay_playing, false)
    |> assign(:timer_generation, socket.assigns.timer_generation + 1)
  end

  defp schedule_replay_tick(socket) do
    delay = replay_delay(socket)
    Process.send_after(self(), {:replay_tick, socket.assigns.timer_generation}, delay)
    socket
  end

  defp replay_delay(socket) do
    raw_delay =
      ReplayTimeline.delay_after(
        socket.assigns.replay_timeline,
        socket.assigns.replay_cursor
      ) || 250

    raw_delay
    |> Kernel./(socket.assigns.replay_speed)
    |> round()
    |> max(50)
    |> min(10_000)
  end

  defp replay_event_count(%{assigns: %{replay_timeline: %ReplayTimeline{} = timeline}}) do
    timeline.event_count
  end

  defp replay_event_count(_socket) do
    0
  end

  defp normalize_mode_params(%{"mode" => "replay"} = params) do
    with {:ok, season} <- replay_season(Map.get(params, "season", Date.utc_today().year)),
         {:ok, session_key} <- optional_session_key(Map.get(params, "session", "")) do
      {:ok, :replay, season, session_key}
    else
      _invalid -> :error
    end
  end

  defp normalize_mode_params(%{"mode" => mode}) when mode not in [nil, "live"] do
    :error
  end

  defp normalize_mode_params(_params) do
    {:ok, :live, Date.utc_today().year, nil}
  end

  defp replay_season(value) do
    with {:ok, season} <- Types.season(value),
         true <- season >= @minimum_replay_season,
         true <- season <= Date.utc_today().year do
      {:ok, season}
    else
      _invalid -> {:error, :invalid_replay_season}
    end
  end

  defp optional_session_key(value) when value in [nil, ""] do
    {:ok, nil}
  end

  defp optional_session_key(value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp optional_session_key(value) when is_binary(value) do
    case Integer.parse(value) do
      {session_key, ""} when session_key >= 0 -> {:ok, session_key}
      _invalid -> {:error, :invalid_session_key}
    end
  end

  defp optional_session_key(_value) do
    {:error, :invalid_session_key}
  end

  defp replay_path(season, nil) do
    ~p"/live-timing?mode=replay&season=#{season}"
  end

  defp replay_path(season, session_key) do
    ~p"/live-timing?mode=replay&season=#{season}&session=#{session_key}"
  end

  defp parse_replay_speed(value) when is_binary(value) do
    case Float.parse(value) do
      {speed, ""} when speed in @replay_speeds -> {:ok, speed}
      _invalid -> :error
    end
  end

  defp parse_replay_speed(_value) do
    :error
  end

  defp speed_value(speed) do
    speed
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  defp speed_label(speed) do
    speed_value(speed) <> "×"
  end

  defp mode_current(mode, expected) do
    if mode == expected, do: "page"
  end

  defp newer_version?(socket, generation, sequence)
       when is_integer(generation) and is_integer(sequence) do
    {generation, sequence} > {socket.assigns.generation, socket.assigns.sequence}
  end

  defp newer_version?(_socket, _generation, _sequence) do
    false
  end

  defp session_name(%RaceProjection{session: %{name: name}})
       when is_binary(name) and name != "—" do
    name
  end

  defp session_name(_projection) do
    "Current session"
  end

  defp replay_loading_message(nil) do
    "Select a past race"
  end

  defp replay_loading_message(_session_key) do
    "Loading replay"
  end

  defp source_label(:open_f1) do
    "OpenF1"
  end

  defp source_label(:jolpica) do
    "Jolpica"
  end

  defp source_label(:fixture) do
    "Fixture feed"
  end

  defp source_label(_source) do
    "Unknown source"
  end

  defp error_state(%Error{kind: :rate_limited}) do
    :rate_limited
  end

  defp error_state(_error) do
    :unavailable
  end

  defp state_label(:inactive) do
    "No active session"
  end

  defp state_label(:connecting) do
    "Connecting"
  end

  defp state_label(:live) do
    "Live"
  end

  defp state_label(:stale) do
    "Delayed"
  end

  defp state_label(:rate_limited) do
    "Rate limited"
  end

  defp state_label(:reconnecting) do
    "Reconnecting"
  end

  defp state_label(:resyncing) do
    "Resynchronizing"
  end

  defp state_label(:degraded) do
    "Last-known"
  end

  defp state_label(:replay) do
    "Replay"
  end

  defp state_label(:unavailable) do
    "Unavailable"
  end

  defp emit_replay_tick(socket, cursor) do
    :telemetry.execute(
      [:vortex, :f1, :replay, :tick],
      %{count: 1, cursor: cursor, event_count: replay_event_count(socket)},
      %{source: socket.assigns.replay_timeline.source, speed: socket.assigns.replay_speed}
    )
  end
end
