defmodule VortexWeb.ResultsLive do
  @moduledoc """
  Owns canonical URL filters and async presentation of completed classifications.

  Results are read only through `Vortex.F1`, streamed with stable driver identity,
  and replaced coherently with their resource freshness metadata.
  """

  use VortexWeb, :live_view

  import VortexWeb.DashboardComponents
  import VortexWeb.ResultsComponents

  alias Vortex.F1
  alias Vortex.F1.Error
  alias Vortex.F1.Resource
  alias Vortex.F1.Types

  @session_kinds [:race, :qualifying, :sprint]
  @fallback_round_limit 24
  @absolute_round_limit 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      F1.subscribe_to_reference_updates()
    end

    {:ok,
     socket
     |> assign(:page_title, "Results")
     |> assign(:theme, "system")
     |> assign(:season, Date.utc_today().year)
     |> assign(:round, 1)
     |> assign(:round_defaulted, true)
     |> assign(:round_options, fallback_round_options())
     |> assign(:session_kind, :race)
     |> assign(:session_kinds, @session_kinds)
     |> assign(:results_state, :loading)
     |> assign(:results_message, "Loading classification")
     |> assign(:resource_meta, nil)
     |> stream_configure(:results, dom_id: &result_dom_id/1)
     |> stream(:results, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    defaults = {Date.utc_today().year, 1, :race}

    case normalize_filters(params, defaults) do
      {:ok, filters} ->
        round_defaulted = not Map.has_key?(params, "round")

        if round_defaulted do
          {season, _round, kind} = filters
          {:noreply, resolve_default_round(socket, season, kind)}
        else
          {:noreply, load_results(socket, filters)}
        end

      :error ->
        {season, round, session_kind} = defaults

        {:noreply,
         push_patch(socket,
           to: results_path(season, round, session_kind)
         )}
    end
  end

  @impl true
  def handle_event("select_result", params, socket) do
    season = Map.get(params, "season", to_string(socket.assigns.season))
    round = Map.get(params, "round", to_string(socket.assigns.round))

    destination =
      with {:ok, normalized_season} <- Types.season(season),
           {:ok, normalized_round} <- Types.round(round) do
        results_path(normalized_season, normalized_round, socket.assigns.session_kind)
      else
        _invalid -> results_path(Date.utc_today().year, 1, :race)
      end

    {:noreply, push_patch(socket, to: destination)}
  end

  @impl true
  def handle_async({:results, filters}, {:ok, {:ok, %Resource{} = resource}}, socket) do
    if current_filters(socket) == filters do
      results = Enum.sort_by(resource.value, &(&1.position || 999))

      {:noreply,
       socket
       |> assign_resource(resource, results)
       |> stream(:results, results, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:results, filters}, {:ok, {:error, %Error{} = error}}, socket) do
    if current_filters(socket) == filters do
      {:noreply, assign_error(socket, error)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:results, filters}, {:exit, _reason}, socket) do
    if current_filters(socket) == filters do
      {:noreply, assign_error(socket, Error.new(:unavailable))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:results, _filters}, _result, socket) do
    {:noreply, socket}
  end

  def handle_async(
        {:result_rounds, season},
        {:ok, {:ok, %Resource{value: meetings}}},
        socket
      )
      when socket.assigns.season == season do
    options = round_options(meetings)

    if options == [] do
      {:noreply, socket}
    else
      round = canonical_round(meetings, socket.assigns.round, socket.assigns.round_defaulted)
      socket = assign(socket, :round_options, options)

      if round == socket.assigns.round and not socket.assigns.round_defaulted do
        {:noreply, socket}
      else
        {:noreply,
         push_patch(socket,
           to: results_path(season, round, socket.assigns.session_kind)
         )}
      end
    end
  end

  def handle_async({:result_rounds, season}, _result, socket)
      when socket.assigns.season == season and socket.assigns.round_defaulted do
    {:noreply,
     push_patch(socket,
       to: results_path(season, 1, socket.assigns.session_kind)
     )}
  end

  def handle_async({:result_rounds, _season}, _result, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {F1, :reference_refreshed, {:results, season, round, kind}, _version},
        socket
      ) do
    filters = {season, round, kind}

    if current_filters(socket) == filters do
      {:noreply, load_results(socket, filters)}
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
      <.dashboard_shell active_page={:results} theme={@theme}>
        <:filters>
          <form id="results-filters" class="compact-filters" phx-change="select_result">
            <label for="results-season">Season</label>
            <input
              id="results-season"
              name="season"
              type="number"
              min="1950"
              max="2100"
              value={@season}
            />
            <label for="results-round">Race</label>
            <select id="results-round" name="round">
              <option
                :for={{round, name} <- @round_options}
                value={round}
                selected={round == @round}
              >
                {round_label(round, name)}
              </option>
            </select>
          </form>

          <nav id="results-session-tabs" class="session-tabs" aria-label="Result session">
            <.link
              :for={kind <- @session_kinds}
              id={"results-session-#{kind}"}
              patch={results_path(@season, @round, kind)}
              aria-current={if kind == @session_kind, do: "page"}
            >
              {session_label(kind)}
            </.link>
          </nav>
        </:filters>

        <section id="results-page" class="dashboard-page" aria-labelledby="results-title">
          <header class="page-header">
            <div>
              <p class="page-kicker">Classification · Round {@round}</p>
              <h1 id="results-title">Results</h1>
            </div>

            <div
              id="results-state"
              class="view-state"
              data-state={@results_state}
              role="status"
              aria-live="polite"
              aria-busy={to_string(@results_state == :loading)}
            >
              <span>{@results_message}</span>
            </div>
          </header>

          <.results_table results={@streams.results} />
        </section>
      </.dashboard_shell>
    </Layouts.app>
    """
  end

  defp resolve_default_round(socket, season, kind) do
    socket
    |> assign(
      season: season,
      round: 1,
      round_defaulted: true,
      round_options: fallback_round_options(),
      session_kind: kind
    )
    |> assign(:results_state, :loading)
    |> assign(:results_message, "Finding latest completed race")
    |> assign(:resource_meta, nil)
    |> stream(:results, [], reset: true)
    |> start_async({:result_rounds, season}, fn -> F1.schedule(season) end)
  end

  defp load_results(socket, {season, round, kind} = filters) do
    round_options =
      if socket.assigns.season == season do
        socket.assigns.round_options
      else
        fallback_round_options()
      end

    socket
    |> assign(
      season: season,
      round: round,
      round_defaulted: false,
      round_options: round_options,
      session_kind: kind
    )
    |> assign(:results_state, :loading)
    |> assign(:results_message, "Loading classification")
    |> assign(:resource_meta, nil)
    |> stream(:results, [], reset: true)
    |> start_async({:results, filters}, fn -> F1.results(season, round, kind) end)
    |> start_async({:result_rounds, season}, fn -> F1.schedule(season) end)
  end

  defp assign_resource(socket, resource, results) do
    state =
      cond do
        resource.freshness == :stale and is_binary(resource.stale_reason) -> :degraded
        resource.freshness == :stale -> :stale
        results == [] -> :empty
        true -> :success
      end

    message =
      case state do
        :success -> "Classification available"
        :empty -> "No classification available"
        :stale -> "Refreshing last-known classification"
        :degraded -> "Showing last-known classification"
      end

    socket
    |> assign(:results_state, state)
    |> assign(:results_message, message)
    |> assign(:resource_meta, Map.take(resource, [:source, :freshness, :version]))
  end

  defp assign_error(socket, error) do
    state = if error.kind == :rate_limited, do: :rate_limited, else: :unavailable

    socket
    |> assign(:results_state, state)
    |> assign(:results_message, error.message)
    |> assign(:resource_meta, nil)
    |> stream(:results, [], reset: true)
  end

  defp normalize_filters(params, {default_season, default_round, default_kind}) do
    with {:ok, season} <- normalize_or_default(params, "season", default_season, &Types.season/1),
         {:ok, round} <- normalize_or_default(params, "round", default_round, &normalize_round/1),
         {:ok, kind} <-
           normalize_or_default(params, "session", default_kind, &Types.session_kind/1),
         true <- kind in @session_kinds do
      {:ok, {season, round, kind}}
    else
      _invalid -> :error
    end
  end

  defp normalize_or_default(params, key, default, normalizer) do
    case Map.fetch(params, key) do
      :error -> {:ok, default}
      {:ok, value} -> normalizer.(value)
    end
  end

  defp normalize_round(value) do
    with {:ok, round} <- Types.round(value),
         true <- round <= @absolute_round_limit do
      {:ok, round}
    else
      _invalid -> {:error, :invalid_round}
    end
  end

  defp round_options(meetings) do
    meetings
    |> Enum.filter(&(is_integer(&1.round) and &1.round > 0))
    |> Enum.sort_by(& &1.round)
    |> Enum.map(&{&1.round, &1.name})
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp canonical_round(meetings, current_round, true) do
    latest_completed_round(meetings) || first_round(meetings) || current_round
  end

  defp canonical_round(meetings, current_round, false) do
    if Enum.any?(meetings, &(&1.round == current_round)) do
      current_round
    else
      first_round(meetings) || current_round
    end
  end

  defp latest_completed_round(meetings) do
    now = DateTime.utc_now()

    meetings
    |> Enum.filter(fn meeting ->
      match?(%DateTime{}, meeting.starts_at) and DateTime.compare(meeting.starts_at, now) != :gt
    end)
    |> Enum.max_by(& &1.starts_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      meeting -> meeting.round
    end
  end

  defp first_round(meetings) do
    meetings
    |> Enum.map(& &1.round)
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp fallback_round_options do
    Enum.map(1..@fallback_round_limit, &{&1, "Round #{&1}"})
  end

  defp round_label(round, "Round " <> round_name) do
    if round_name == Integer.to_string(round) do
      "Round #{round}"
    else
      "Round #{round} · Round #{round_name}"
    end
  end

  defp round_label(round, name) do
    "Round #{round} · #{name}"
  end

  defp current_filters(socket) do
    {socket.assigns.season, socket.assigns.round, socket.assigns.session_kind}
  end

  defp result_dom_id(%{driver: %{ref: ref}}) do
    "result-row-#{ref}"
  end

  defp result_dom_id(%{id: id}) do
    "result-row-#{id}"
  end

  defp results_path(season, round, kind) do
    ~p"/results?#{[round: round, season: season, session: Atom.to_string(kind)]}"
  end

  defp session_label(:race) do
    "Race"
  end

  defp session_label(:qualifying) do
    "Qualifying"
  end

  defp session_label(:sprint) do
    "Sprint"
  end
end
