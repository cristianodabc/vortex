defmodule VortexWeb.ScheduleComponents do
  @moduledoc "Presentation components for the race-calendar master/detail workspace."

  use VortexWeb, :html

  alias Vortex.F1.Meeting
  alias Vortex.F1.Session

  attr :days, :list, required: true
  attr :month, :integer, required: true
  attr :season, :integer, required: true
  attr :selected_round, :integer, default: nil
  attr :empty, :boolean, default: false
  attr :now, DateTime, required: true
  attr :previous_path, :string, default: nil
  attr :next_path, :string, default: nil
  attr :today_path, :string, required: true

  @doc "Renders one semantic six-week month grid with keyboard-operable race links."
  @spec schedule_calendar(map()) :: Phoenix.LiveView.Rendered.t()
  def schedule_calendar(assigns) do
    assigns = assign(assigns, :month_label, month_label(assigns.season, assigns.month))

    ~H"""
    <section class="schedule-calendar-panel" aria-labelledby="schedule-calendar-title">
      <header class="calendar-toolbar">
        <.month_control
          id="schedule-previous-month"
          label="Previous month"
          path={@previous_path}
          icon="hero-chevron-left"
        />
        <h2 id="schedule-calendar-title">{@month_label}</h2>
        <div class="calendar-toolbar-actions">
          <.link
            id="schedule-current-month"
            class="calendar-today"
            aria-label="Go to the current month"
            patch={@today_path}
          >
            Today
          </.link>
          <.month_control
            id="schedule-next-month"
            label="Next month"
            path={@next_path}
            icon="hero-chevron-right"
          />
        </div>
      </header>

      <div
        id="schedule-calendar"
        class="schedule-calendar"
        role="grid"
        aria-labelledby="schedule-calendar-title"
      >
        <div id="schedule-weekdays" class="schedule-weekdays" role="row">
          <span :for={{short, full} <- weekday_labels()} role="columnheader" aria-label={full}>
            {short}
          </span>
        </div>

        <div id="schedule-days" class="schedule-days" role="rowgroup">
          <div
            :for={day <- @days}
            id={"schedule-day-#{Date.to_iso8601(day.date)}"}
            class={["schedule-day", !day.in_month? && "is-outside-month"]}
            role="gridcell"
            data-in-month={to_string(day.in_month?)}
          >
            <time datetime={Date.to_iso8601(day.date)}>{day.date.day}</time>
            <.link
              :for={meeting <- day.meetings}
              id={"schedule-event-round-#{meeting.round}"}
              class="schedule-event"
              data-status={meeting_status(meeting, @now)}
              aria-current={if meeting.round == @selected_round, do: "page"}
              patch={schedule_path(@season, @month, meeting.round)}
            >
              <span class="schedule-event-round">R{meeting.round}</span>
              <span class="schedule-event-name">{meeting.name}</span>
            </.link>
          </div>
        </div>
      </div>

      <div :if={@empty} id="schedule-empty" class="schedule-empty">
        <p>No races are available for this season.</p>
      </div>
    </section>
    """
  end

  attr :meeting, Meeting, default: nil
  attr :now, DateTime, required: true

  @doc "Renders the selected race weekend in a focused right-side detail panel."
  @spec meeting_details(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_details(%{meeting: nil} = assigns) do
    ~H"""
    <aside id="schedule-detail-empty" class="schedule-detail-panel" aria-live="polite">
      <div class="schedule-detail-placeholder">
        <.icon name="hero-calendar-days" class="size-5" />
        <p>Select a race date to inspect the weekend schedule.</p>
      </div>
    </aside>
    """
  end

  def meeting_details(assigns) do
    status = meeting_status(assigns.meeting, assigns.now)
    assigns = assign(assigns, :status, status)

    ~H"""
    <aside
      id={"schedule-detail-round-#{@meeting.round}"}
      class="schedule-detail-panel"
      aria-labelledby={"schedule-detail-title-#{@meeting.round}"}
      aria-live="polite"
    >
      <article id={"schedule-round-#{@meeting.round}"} data-status={@status}>
        <header class="schedule-detail-header">
          <div>
            <p class="schedule-round-label">Round {@meeting.round}</p>
            <h2 id={"schedule-detail-title-#{@meeting.round}"}>{@meeting.name}</h2>
          </div>
          <span class="schedule-status" data-status={@status}>{status_label(@status)}</span>
        </header>

        <dl class="schedule-facts">
          <div>
            <dt>Circuit</dt>
            <dd>{@meeting.circuit_name}</dd>
          </div>
          <div>
            <dt>Location</dt>
            <dd>{@meeting.locality}, {@meeting.country}</dd>
          </div>
          <div>
            <dt>Race start</dt>
            <dd>
              <time :if={@meeting.starts_at} datetime={DateTime.to_iso8601(@meeting.starts_at)}>
                {Calendar.strftime(@meeting.starts_at, "%a %d %b · %H:%M UTC")}
              </time>
              <span :if={!@meeting.starts_at}>Time pending</span>
            </dd>
          </div>
        </dl>

        <section class="schedule-detail-sessions" aria-labelledby={"session-list-#{@meeting.round}"}>
          <h3 id={"session-list-#{@meeting.round}"}>Weekend sessions</h3>
          <.session_fact
            :for={session <- @meeting.sessions}
            id={"schedule-session-#{@meeting.round}-#{session.kind}"}
            session={session}
          />
        </section>
      </article>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :session, Session, required: true

  @doc "Renders a labeled session date and time from normalized values."
  @spec session_fact(map()) :: Phoenix.LiveView.Rendered.t()
  def session_fact(assigns) do
    ~H"""
    <div id={@id} class="schedule-session">
      <span class="schedule-session-name">{@session.name}</span>
      <time :if={@session.starts_at} datetime={DateTime.to_iso8601(@session.starts_at)}>
        {Calendar.strftime(@session.starts_at, "%a %d %b · %H:%M UTC")}
      </time>
      <span :if={!@session.starts_at} aria-label={"#{@session.name} time unavailable"}>—</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :path, :string, default: nil
  attr :icon, :string, required: true

  defp month_control(%{path: nil} = assigns) do
    ~H"""
    <span id={@id} class="calendar-control is-disabled" aria-label={@label} aria-disabled="true">
      <.icon name={@icon} class="size-3.5" />
    </span>
    """
  end

  defp month_control(assigns) do
    ~H"""
    <.link id={@id} class="calendar-control" aria-label={@label} patch={@path}>
      <.icon name={@icon} class="size-3.5" />
    </.link>
    """
  end

  defp weekday_labels do
    [
      {"Mon", "Monday"},
      {"Tue", "Tuesday"},
      {"Wed", "Wednesday"},
      {"Thu", "Thursday"},
      {"Fri", "Friday"},
      {"Sat", "Saturday"},
      {"Sun", "Sunday"}
    ]
  end

  defp month_label(season, month) do
    season
    |> Date.new!(month, 1)
    |> Calendar.strftime("%B %Y")
  end

  defp schedule_path(season, month, round) do
    ~p"/schedule?#{[month: month, round: round, season: season]}"
  end

  defp meeting_status(meeting, now) do
    windows = meeting_windows(meeting)

    cond do
      Enum.any?(windows, &inside_window?(now, &1)) -> :in_progress
      windows != [] and Enum.all?(windows, &window_completed?(now, &1)) -> :completed
      windows != [] -> :upcoming
      true -> :unknown
    end
  end

  defp meeting_windows(%Meeting{sessions: sessions} = meeting) do
    windows = Enum.flat_map(sessions, &session_window/1)

    if windows == [] do
      meeting_window(meeting)
    else
      windows
    end
  end

  defp session_window(%Session{starts_at: %DateTime{} = starts_at, ends_at: ends_at}) do
    [{starts_at, ends_at || DateTime.add(starts_at, 3, :hour)}]
  end

  defp session_window(_session) do
    []
  end

  defp meeting_window(%Meeting{starts_at: %DateTime{} = starts_at}) do
    [{starts_at, DateTime.add(starts_at, 3, :hour)}]
  end

  defp meeting_window(_meeting) do
    []
  end

  defp inside_window?(now, {starts_at, ends_at}) do
    DateTime.compare(now, starts_at) != :lt and DateTime.compare(now, ends_at) == :lt
  end

  defp window_completed?(now, {_starts_at, ends_at}) do
    DateTime.compare(now, ends_at) != :lt
  end

  defp status_label(:completed) do
    "Completed"
  end

  defp status_label(:in_progress) do
    "In progress"
  end

  defp status_label(:upcoming) do
    "Upcoming"
  end

  defp status_label(:unknown) do
    "Time pending"
  end
end
