defmodule VortexWeb.ResultsComponents do
  @moduledoc "Presentation-only components for normalized session classifications."

  use VortexWeb, :html

  alias Vortex.F1.Types

  attr :results, :any, required: true

  @doc "Renders a responsive classification table backed by a LiveView stream."
  @spec results_table(map()) :: Phoenix.LiveView.Rendered.t()
  def results_table(assigns) do
    ~H"""
    <div id="results-table" class="data-table-panel">
      <table>
        <caption class="sr-only">Session classification</caption>
        <thead>
          <tr>
            <th scope="col">Pos</th>
            <th scope="col">Driver</th>
            <th scope="col" class="optional-column">Constructor</th>
            <th scope="col" class="optional-column">Grid</th>
            <th scope="col">Time / status</th>
            <th scope="col">Points</th>
          </tr>
        </thead>
        <tbody id="result-rows" phx-update="stream">
          <tr id="results-empty" class="only:table-row hidden">
            <td colspan="6">No classification is available for this session.</td>
          </tr>
          <.result_row :for={{dom_id, result} <- @results} id={dom_id} result={result} />
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :result, Vortex.F1.Result, required: true

  @doc "Renders one normalized classification row with neutral missing values."
  @spec result_row(map()) :: Phoenix.LiveView.Rendered.t()
  def result_row(assigns) do
    assigns = assign(assigns, :team_colour, team_colour(assigns.result))

    ~H"""
    <tr id={@id}>
      <td class="position-cell">{@result.position || "—"}</td>
      <td class="identity-cell" style={"--team-colour: ##{@team_colour}"}>
        <span
          class="team-marker"
          data-team-colour={@team_colour}
          aria-hidden="true"
        ></span>
        <span class="driver-code">
          {driver_value(@result, :code)}
        </span>
        <span class="driver-name">{driver_value(@result, :display_name)}</span>
        <span :if={@result.fastest_lap} class="fastest-lap">
          Fastest lap · {@result.fastest_lap}
        </span>
      </td>
      <td class="optional-column">{constructor_name(@result)}</td>
      <td class="optional-column">{@result.grid || "—"}</td>
      <td>
        <span>{primary_status(@result)}</span>
        <span :if={qualifying_times?(@result)} class="qualifying-splits">
          <span :if={@result.q1}>Q1 {@result.q1}</span>
          <span :if={@result.q2}>Q2 {@result.q2}</span>
          <span :if={@result.q3}>Q3 {@result.q3}</span>
        </span>
        <span class="secondary-value">{@result.status}</span>
      </td>
      <td class="points-cell">{number(@result.points)}</td>
    </tr>
    """
  end

  defp driver_value(%{driver: driver}, field) when is_map(driver) do
    Map.get(driver, field) || "—"
  end

  defp driver_value(_result, _field) do
    "—"
  end

  defp constructor_name(%{constructor: %{name: name}}) do
    name
  end

  defp constructor_name(_result) do
    "—"
  end

  defp team_colour(%{constructor: %{colour: colour}}) do
    Types.team_colour(colour)
  end

  defp team_colour(_result) do
    Types.neutral_team_colour()
  end

  defp primary_status(%{time: time}) when is_binary(time) and time != "—" do
    time
  end

  defp primary_status(%{gap: gap}) when is_binary(gap) and gap != "—" do
    gap
  end

  defp primary_status(%{status: status}) do
    status
  end

  defp qualifying_times?(%{q1: q1, q2: q2, q3: q3}) do
    is_binary(q1) or is_binary(q2) or is_binary(q3)
  end

  defp qualifying_times?(_result) do
    false
  end

  defp number(value) when is_float(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  defp number(value) do
    to_string(value)
  end
end
