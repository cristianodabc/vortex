defmodule VortexWeb.ScheduleLive do
  @moduledoc """
  Owns URL selection and async lifecycle for the race-calendar master/detail view.

  The selected season, month, and round are canonical URL state. Provider data
  is loaded only through `Vortex.F1`; the socket retains one small normalized
  season and derives a bounded 42-day month grid plus one selected meeting.
  """

  use VortexWeb, :live_view

  import VortexWeb.DashboardComponents
  import VortexWeb.ScheduleComponents

  alias Vortex.F1
  alias Vortex.F1.Error
  alias Vortex.F1.Resource
  alias Vortex.F1.Types

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      F1.subscribe_to_reference_updates()
    end

    today = Date.utc_today()
    now = DateTime.utc_now()

    {:ok,
     socket
     |> assign(:page_title, "Schedule")
     |> assign(:theme, "system")
     |> assign(:season, today.year)
     |> assign(:month, today.month)
     |> assign(:requested_month, nil)
     |> assign(:requested_round, nil)
     |> assign(:selected_round, nil)
     |> assign(:selected_meeting, nil)
     |> assign(:meetings, [])
     |> assign(:calendar_days, calendar_days(today.year, today.month, []))
     |> assign(:now, now)
     |> assign(:schedule_state, :loading)
     |> assign(:schedule_message, "Loading schedule")
     |> assign(:resource_meta, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case normalize_filters(params) do
      {:ok, filters} ->
        {:noreply, load_schedule(socket, filters)}

      :error ->
        {:noreply, push_patch(socket, to: ~p"/schedule?season=#{Date.utc_today().year}")}
    end
  end

  @impl true
  def handle_event("select_season", %{"season" => season}, socket) do
    destination =
      case Types.season(season) do
        {:ok, normalized_season} -> ~p"/schedule?season=#{normalized_season}"
        {:error, _reason} -> ~p"/schedule?season=#{Date.utc_today().year}"
      end

    {:noreply, push_patch(socket, to: destination)}
  end

  @impl true
  def handle_async({:schedule, season}, {:ok, {:ok, %Resource{} = resource}}, socket)
      when socket.assigns.season == season do
    meetings = Enum.sort_by(resource.value, &meeting_sort_key/1)
    selection = resolve_selection(socket, meetings)

    socket =
      socket
      |> assign_schedule(resource, meetings, selection)
      |> maybe_canonicalize_selection(selection)

    {:noreply, socket}
  end

  def handle_async({:schedule, season}, {:ok, {:error, %Error{} = error}}, socket)
      when socket.assigns.season == season do
    {:noreply, assign_error(socket, error)}
  end

  def handle_async({:schedule, season}, {:exit, _reason}, socket)
      when socket.assigns.season == season do
    {:noreply, assign_error(socket, Error.new(:unavailable))}
  end

  def handle_async({:schedule, _season}, _result, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {F1, :reference_refreshed, {:schedule, season}, _version},
        %{assigns: %{season: season}} = socket
      ) do
    filters = %{
      season: season,
      month: socket.assigns.requested_month,
      round: socket.assigns.requested_round
    }

    {:noreply, load_schedule(socket, filters)}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.dashboard_shell active_page={:schedule} theme={@theme}>
        <:filters>
          <form id="schedule-filters" phx-change="select_season">
            <label for="schedule-season">Season</label>
            <select id="schedule-season" name="season">
              <option
                :for={season <- Date.utc_today().year..1950//-1}
                value={season}
                selected={season == @season}
              >
                {season}
              </option>
            </select>
          </form>
        </:filters>

        <section id="schedule-page" class="dashboard-page" aria-labelledby="schedule-title">
          <header class="page-header">
            <div>
              <p class="page-kicker">Race calendar</p>
              <h1 id="schedule-title">Schedule</h1>
            </div>

            <div
              id="schedule-state"
              class="view-state"
              data-state={@schedule_state}
              role="status"
              aria-live="polite"
              aria-busy={to_string(@schedule_state == :loading)}
            >
              <span>{@schedule_message}</span>
              <span :if={@resource_meta} id="schedule-freshness">
                {freshness_label(@resource_meta.freshness)}
              </span>
            </div>
          </header>

          <div class="schedule-workspace">
            <.schedule_calendar
              days={@calendar_days}
              month={@month}
              season={@season}
              selected_round={@selected_round}
              empty={@meetings == [] and @schedule_state != :loading}
              now={@now}
              previous_path={month_path(@season, @month - 1)}
              next_path={month_path(@season, @month + 1)}
              today_path={month_path(Date.utc_today().year, Date.utc_today().month)}
            />
            <.meeting_details meeting={@selected_meeting} now={@now} />
          </div>
        </section>
      </.dashboard_shell>
    </Layouts.app>
    """
  end

  defp normalize_filters(params) do
    with {:ok, season} <- normalize_season(Map.get(params, "season")),
         {:ok, month} <- normalize_optional_month(Map.get(params, "month")),
         {:ok, round} <- normalize_optional_round(Map.get(params, "round")) do
      {:ok, %{season: season, month: month, round: round}}
    else
      _invalid -> :error
    end
  end

  defp normalize_season(nil) do
    {:ok, Date.utc_today().year}
  end

  defp normalize_season(season) do
    Types.season(season)
  end

  defp normalize_optional_month(nil) do
    {:ok, nil}
  end

  defp normalize_optional_month(month) do
    case Integer.parse(to_string(month)) do
      {normalized, ""} when normalized in 1..12 -> {:ok, normalized}
      _invalid -> {:error, :invalid_month}
    end
  end

  defp normalize_optional_round(nil) do
    {:ok, nil}
  end

  defp normalize_optional_round(round) do
    Types.round(round)
  end

  defp load_schedule(socket, filters) do
    visible_month = filters.month || default_month(filters.season)

    socket
    |> assign(:season, filters.season)
    |> assign(:month, visible_month)
    |> assign(:requested_month, filters.month)
    |> assign(:requested_round, filters.round)
    |> assign(:selected_round, filters.round)
    |> assign(:selected_meeting, nil)
    |> assign(:calendar_days, calendar_days(filters.season, visible_month, []))
    |> assign(:schedule_state, :loading)
    |> assign(:schedule_message, "Loading schedule")
    |> assign(:resource_meta, nil)
    |> start_async({:schedule, filters.season}, fn -> F1.schedule(filters.season) end)
  end

  defp assign_schedule(socket, resource, meetings, selection) do
    resource_meta = %{
      source: resource.source,
      fetched_at: resource.fetched_at,
      freshness: resource.freshness,
      stale_reason: resource.stale_reason,
      version: resource.version
    }

    {state, message} = resource_state(resource, meetings)

    socket
    |> assign(:month, selection.month)
    |> assign(:selected_round, selection.round)
    |> assign(:selected_meeting, selection.meeting)
    |> assign(:meetings, meetings)
    |> assign(:calendar_days, calendar_days(socket.assigns.season, selection.month, meetings))
    |> assign(:schedule_state, state)
    |> assign(:schedule_message, message)
    |> assign(:resource_meta, resource_meta)
  end

  defp assign_error(socket, error) do
    state = if error.kind == :rate_limited, do: :rate_limited, else: :unavailable

    socket
    |> assign(:schedule_state, state)
    |> assign(:schedule_message, error.message)
    |> assign(:resource_meta, nil)
    |> assign(:selected_meeting, nil)
    |> assign(:meetings, [])
  end

  defp resolve_selection(socket, meetings) do
    requested_round = socket.assigns.requested_round
    requested_month = socket.assigns.requested_month

    meeting =
      find_round(meetings, requested_round) ||
        first_in_month(meetings, requested_month) ||
        default_meeting(meetings, socket.assigns.now)

    month = meeting_month(meeting) || requested_month || default_month(socket.assigns.season)

    %{meeting: meeting, month: month, round: meeting && meeting.round}
  end

  defp maybe_canonicalize_selection(socket, %{meeting: nil}) do
    socket
  end

  defp maybe_canonicalize_selection(socket, selection) do
    if socket.assigns.requested_month == selection.month and
         socket.assigns.requested_round == selection.round do
      socket
    else
      push_patch(socket,
        to: schedule_path(socket.assigns.season, selection.month, selection.round)
      )
    end
  end

  defp find_round(_meetings, nil) do
    nil
  end

  defp find_round(meetings, round) do
    Enum.find(meetings, &(&1.round == round))
  end

  defp first_in_month(_meetings, nil) do
    nil
  end

  defp first_in_month(meetings, month) do
    Enum.find(meetings, &(meeting_month(&1) == month))
  end

  defp default_meeting([], _now) do
    nil
  end

  defp default_meeting(meetings, now) do
    Enum.find(meetings, fn meeting ->
      match?(%DateTime{}, meeting.starts_at) and DateTime.compare(meeting.starts_at, now) != :lt
    end) || List.last(meetings)
  end

  defp calendar_days(season, month, meetings) do
    first = Date.new!(season, month, 1)
    grid_start = Date.add(first, -(Date.day_of_week(first) - 1))
    meetings_by_date = Enum.group_by(meetings, &meeting_date/1)

    Enum.map(0..41, fn offset ->
      date = Date.add(grid_start, offset)

      %{
        date: date,
        in_month?: date.month == month,
        meetings: Map.get(meetings_by_date, date, [])
      }
    end)
  end

  defp meeting_date(%{starts_at: %DateTime{} = starts_at}) do
    DateTime.to_date(starts_at)
  end

  defp meeting_date(_meeting) do
    nil
  end

  defp meeting_month(%{starts_at: %DateTime{} = starts_at}) do
    starts_at.month
  end

  defp meeting_month(_meeting) do
    nil
  end

  defp default_month(season) do
    if season == Date.utc_today().year do
      Date.utc_today().month
    else
      1
    end
  end

  defp resource_state(%Resource{freshness: :stale, stale_reason: reason}, _meetings)
       when is_binary(reason) do
    {:degraded, "Showing last-known schedule"}
  end

  defp resource_state(%Resource{freshness: :stale}, _meetings) do
    {:stale, "Refreshing last-known schedule"}
  end

  defp resource_state(_resource, []) do
    {:empty, "No races available"}
  end

  defp resource_state(_resource, _meetings) do
    {:success, "Schedule available"}
  end

  defp meeting_sort_key(%{starts_at: %DateTime{} = starts_at, round: round}) do
    {DateTime.to_unix(starts_at, :microsecond), round || 0}
  end

  defp meeting_sort_key(%{round: round}) do
    {9_223_372_036_854_775_807, round || 0}
  end

  defp schedule_path(season, month, round) do
    ~p"/schedule?#{[month: month, round: round, season: season]}"
  end

  defp month_path(_season, month) when month not in 1..12 do
    nil
  end

  defp month_path(season, month) do
    ~p"/schedule?#{[month: month, season: season]}"
  end

  defp freshness_label(:fresh) do
    "Fresh"
  end

  defp freshness_label(:stale) do
    "Stale"
  end
end
