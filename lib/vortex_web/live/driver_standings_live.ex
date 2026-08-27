defmodule VortexWeb.DriverStandingsLive do
  @moduledoc "Owns URL filters, async reads, and stable rows for driver standings."

  use VortexWeb, :live_view

  import VortexWeb.DashboardComponents
  import VortexWeb.StandingsComponents

  alias Vortex.F1
  alias Vortex.F1.Error
  alias Vortex.F1.Resource
  alias Vortex.F1.Types

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      F1.subscribe_to_reference_updates()
    end

    {:ok,
     socket
     |> assign(:page_title, "Driver standings")
     |> assign(:theme, "system")
     |> assign(:season, Date.utc_today().year)
     |> assign(:view_state, :loading)
     |> assign(:view_message, "Loading driver standings")
     |> stream_configure(:driver_standings, dom_id: &dom_id/1)
     |> stream(:driver_standings, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    case season(params) do
      {:ok, value} -> {:noreply, load(socket, value)}
      :error -> {:noreply, push_patch(socket, to: path(Date.utc_today().year))}
    end
  end

  @impl true
  def handle_event("select_driver_season", %{"season" => value}, socket) do
    destination =
      case Types.season(value) do
        {:ok, value} -> path(value)
        _invalid -> path(Date.utc_today().year)
      end

    {:noreply, push_patch(socket, to: destination)}
  end

  @impl true
  def handle_async({:driver_standings, season}, {:ok, result}, socket) do
    if socket.assigns.season == season do
      complete(result, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_async({:driver_standings, season}, {:exit, _reason}, socket) do
    if socket.assigns.season == season do
      complete({:error, Error.new(:unavailable)}, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({F1, :reference_refreshed, {:driver_standings, season}, _version}, socket) do
    if socket.assigns.season == season do
      {:noreply, load(socket, season)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.dashboard_shell active_page={:driver_standings} theme={@theme}>
        <:filters>
          <.season_filter id="driver-standings-filters" event="select_driver_season" season={@season} />
        </:filters>
        <section
          id="driver-standings-page"
          class="dashboard-page"
          aria-labelledby="driver-standings-title"
        >
          <header class="page-header">
            <div>
              <p class="page-kicker">Championship</p>
              <h1 id="driver-standings-title">
                Driver standings
              </h1>
            </div>
            <div
              id="driver-standings-state"
              class="view-state"
              data-state={@view_state}
              role="status"
              aria-live="polite"
              aria-busy={to_string(@view_state == :loading)}
            >
              {@view_message}
            </div>
          </header>
          <.driver_table standings={@streams.driver_standings} />
        </section>
      </.dashboard_shell>
    </Layouts.app>
    """
  end

  defp load(socket, season) do
    socket
    |> assign(:season, season)
    |> assign(:view_state, :loading)
    |> assign(:view_message, "Loading driver standings")
    |> stream(:driver_standings, [], reset: true)
    |> start_async({:driver_standings, season}, fn -> F1.driver_standings(season) end)
  end

  defp complete({:ok, %Resource{} = resource}, socket) do
    rows = Enum.sort_by(resource.value, &(&1.position || 999))
    {state, message} = state(resource, rows)

    {:noreply,
     socket
     |> assign(view_state: state, view_message: message)
     |> stream(:driver_standings, rows, reset: true)}
  end

  defp complete({:error, %Error{} = error}, socket) do
    state = if error.kind == :rate_limited, do: :rate_limited, else: :unavailable

    {:noreply,
     socket
     |> assign(view_state: state, view_message: error.message)
     |> stream(:driver_standings, [], reset: true)}
  end

  defp state(%Resource{freshness: :stale, stale_reason: reason}, _rows)
       when is_binary(reason) do
    {:degraded, "Showing last-known standings"}
  end

  defp state(%Resource{freshness: :stale}, _rows) do
    {:stale, "Refreshing last-known standings"}
  end

  defp state(_resource, []) do
    {:empty, "No driver standings available"}
  end

  defp state(_resource, _rows) do
    {:success, "Driver standings available"}
  end

  defp season(params) do
    case Map.fetch(params, "season") do
      :error ->
        {:ok, Date.utc_today().year}

      {:ok, value} ->
        case Types.season(value) do
          {:ok, value} -> {:ok, value}
          _invalid -> :error
        end
    end
  end

  defp dom_id(%{driver: %{ref: ref}}) do
    "driver-standing-row-#{ref}"
  end

  defp dom_id(%{id: id}) do
    "driver-standing-row-#{id}"
  end

  defp path(season) do
    ~p"/standings/drivers?season=#{season}"
  end
end
