defmodule VortexWeb.LiveTimingComponents do
  @moduledoc "Presentation-only components for the bounded current-session timing tower."

  use VortexWeb, :html

  alias Vortex.F1.TimingRow
  alias Vortex.F1.Types

  attr :rows, :any, required: true

  @doc "Renders current timing rows as an accessible, stream-backed table."
  @spec timing_table(map()) :: Phoenix.LiveView.Rendered.t()
  def timing_table(assigns) do
    ~H"""
    <div id="live-timing-table" class="data-table-panel timing-table-panel">
      <table>
        <caption class="sr-only">Current session timing order</caption>
        <thead>
          <tr>
            <th scope="col">Pos</th>
            <th scope="col">Driver</th>
            <th scope="col">Gap</th>
            <th scope="col">Interval</th>
            <th scope="col" class="optional-column">Last lap</th>
            <th scope="col">Best lap</th>
            <th scope="col">Tyre</th>
            <th scope="col" class="optional-column">Track</th>
          </tr>
        </thead>
        <tbody id="timing-rows" phx-update="stream">
          <tr id="timing-empty" class="only:table-row hidden">
            <td colspan="8">No timing rows are available for this session.</td>
          </tr>
          <.timing_row :for={{dom_id, row} <- @rows} id={dom_id} row={row} />
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, TimingRow, required: true

  @doc "Renders one timing row with a validated provider team-color bar."
  @spec timing_row(map()) :: Phoenix.LiveView.Rendered.t()
  def timing_row(assigns) do
    assigns =
      assigns
      |> assign(:driver, assigns.row.driver)
      |> assign(:team_colour, team_colour(assigns.row))

    ~H"""
    <tr id={@id}>
      <td class="position-cell timing-number">{@row.position || "—"}</td>
      <td class="identity-cell" style={"--team-colour: ##{@team_colour}"}>
        <span
          class="team-marker"
          data-team-colour={@team_colour}
          aria-hidden="true"
        ></span>
        <span class="driver-code">{driver_value(@driver, :code)}</span>
        <span class="driver-name">{driver_value(@driver, :display_name)}</span>
      </td>
      <td class="timing-number">{@row.gap}</td>
      <td class="timing-number">{@row.interval}</td>
      <td class="timing-number optional-column">{@row.last_lap}</td>
      <td class="timing-number">{@row.best_lap}</td>
      <td>
        <.tyre_badge tyre={@row.tyre} age={@row.tyre_age} />
      </td>
      <td class="optional-column">
        <span class="pit-state" data-pit-state={@row.pit_state}>
          {pit_label(@row.pit_state, @row.status)}
        </span>
      </td>
    </tr>
    """
  end

  attr :tyre, :atom, required: true
  attr :age, :integer, default: nil

  @doc "Renders a text-labelled tyre compound badge; color is never the only cue."
  @spec tyre_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def tyre_badge(assigns) do
    ~H"""
    <span class="tyre-badge" data-tyre={@tyre}>
      {tyre_label(@tyre)}<span :if={@age} class="tyre-age"> · {@age}L</span>
    </span>
    """
  end

  defp team_colour(%TimingRow{team_colour: colour, driver: driver}) do
    case Types.team_colour(colour) do
      "737373" -> driver_team_colour(driver)
      validated -> validated
    end
  end

  defp driver_team_colour(%{team_colour: colour}) do
    Types.team_colour(colour)
  end

  defp driver_team_colour(_driver) do
    Types.neutral_team_colour()
  end

  defp driver_value(driver, field) when is_map(driver) do
    Map.get(driver, field) || "—"
  end

  defp driver_value(_driver, _field) do
    "—"
  end

  defp tyre_label(:soft) do
    "Soft"
  end

  defp tyre_label(:medium) do
    "Medium"
  end

  defp tyre_label(:hard) do
    "Hard"
  end

  defp tyre_label(:intermediate) do
    "Intermediate"
  end

  defp tyre_label(:wet) do
    "Wet"
  end

  defp tyre_label(_tyre) do
    "Unknown"
  end

  defp pit_label(:pit_in, _status) do
    "Pit in"
  end

  defp pit_label(:pit, _status) do
    "In pit"
  end

  defp pit_label(:pit_out, _status) do
    "Pit out"
  end

  defp pit_label(:track, status) when is_binary(status) and status != "—" do
    status
  end

  defp pit_label(_pit_state, status) when is_binary(status) do
    status
  end

  defp pit_label(_pit_state, _status) do
    "—"
  end
end
