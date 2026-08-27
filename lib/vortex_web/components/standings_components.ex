defmodule VortexWeb.StandingsComponents do
  @moduledoc """
  Stateless presentation components shared by both championship tables.

  Team colors are revalidated defensively and appear only on a narrow marker;
  names, codes, positions, and labels remain the primary identity signals.
  """

  use VortexWeb, :html

  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Types

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :season, :integer, required: true

  @doc "Renders a bounded season filter for either standings route."
  @spec season_filter(map()) :: Phoenix.LiveView.Rendered.t()
  def season_filter(assigns) do
    ~H"""
    <form id={@id} class="compact-filters" phx-change={@event}>
      <label for={"#{@id}-season"}>Season</label>
      <select id={"#{@id}-season"} name="season">
        <option
          :for={season <- Date.utc_today().year..1950//-1}
          value={season}
          selected={season == @season}
        >
          {season}
        </option>
      </select>
    </form>
    """
  end

  attr :standings, :any, required: true

  @doc "Renders driver standings using stable stream IDs and semantic columns."
  @spec driver_table(map()) :: Phoenix.LiveView.Rendered.t()
  def driver_table(assigns) do
    ~H"""
    <div id="driver-standings-table" class="data-table-panel">
      <table>
        <caption class="sr-only">Driver championship standings</caption>
        <thead>
          <tr>
            <th scope="col">Pos</th>
            <th scope="col">Driver</th>
            <th scope="col">Team</th>
            <th scope="col">Wins</th>
            <th scope="col">Points</th>
          </tr>
        </thead>
        <tbody id="driver-standing-rows" phx-update="stream">
          <tr id="driver-standings-empty" class="only:table-row hidden">
            <td colspan="5">No driver standings are available.</td>
          </tr>
          <.driver_row :for={{id, standing} <- @standings} id={id} standing={standing} />
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :standing, DriverStanding, required: true

  @doc "Renders one driver standing with text identity and a narrow team marker."
  @spec driver_row(map()) :: Phoenix.LiveView.Rendered.t()
  def driver_row(assigns) do
    colour = driver_colour(assigns.standing)
    assigns = assign(assigns, :colour, colour)

    ~H"""
    <tr id={@id}>
      <td class="position-cell">{@standing.position || "—"}</td>
      <td class="identity-cell" style={"--team-colour: ##{@colour}"}>
        <span
          class="team-marker"
          data-team-colour={@colour}
          aria-hidden="true"
        ></span>
        <span class="driver-code">{driver_value(@standing, :code)}</span>
        <span class="driver-name">{driver_value(@standing, :display_name)}</span>
      </td>
      <td>{constructor_names(@standing)}</td>
      <td>{@standing.wins}</td>
      <td class="points-cell">{number(@standing.points)}</td>
    </tr>
    """
  end

  attr :standings, :any, required: true

  @doc "Renders constructor standings using stable stream IDs and semantic columns."
  @spec constructor_table(map()) :: Phoenix.LiveView.Rendered.t()
  def constructor_table(assigns) do
    ~H"""
    <div id="constructor-standings-table" class="data-table-panel">
      <table>
        <caption class="sr-only">Constructor championship standings</caption>
        <thead>
          <tr>
            <th scope="col">Pos</th>
            <th scope="col">Constructor</th>
            <th scope="col">Nationality</th>
            <th scope="col">Wins</th>
            <th scope="col">Points</th>
          </tr>
        </thead>
        <tbody id="constructor-standing-rows" phx-update="stream">
          <tr id="constructor-standings-empty" class="only:table-row hidden">
            <td colspan="5">No constructor standings are available.</td>
          </tr>
          <.constructor_row :for={{id, standing} <- @standings} id={id} standing={standing} />
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :standing, ConstructorStanding, required: true

  @doc "Renders one constructor standing with nationality text and a narrow team marker."
  @spec constructor_row(map()) :: Phoenix.LiveView.Rendered.t()
  def constructor_row(assigns) do
    colour = constructor_colour(assigns.standing)
    assigns = assign(assigns, :colour, colour)

    ~H"""
    <tr id={@id}>
      <td class="position-cell">{@standing.position || "—"}</td>
      <td class="identity-cell" style={"--team-colour: ##{@colour}"}>
        <span
          class="team-marker"
          data-team-colour={@colour}
          aria-hidden="true"
        ></span>
        <span>{constructor_value(@standing, :name)}</span>
      </td>
      <td>{constructor_value(@standing, :nationality)}</td>
      <td>{@standing.wins}</td>
      <td class="points-cell">{number(@standing.points)}</td>
    </tr>
    """
  end

  defp driver_colour(%{driver: %{team_colour: colour}}) do
    Types.team_colour(colour)
  end

  defp driver_colour(_standing) do
    Types.neutral_team_colour()
  end

  defp constructor_colour(%{constructor: %{colour: colour}}) do
    Types.team_colour(colour)
  end

  defp constructor_colour(_standing) do
    Types.neutral_team_colour()
  end

  defp driver_value(%{driver: driver}, field) when is_map(driver) do
    Map.get(driver, field) || "—"
  end

  defp driver_value(_standing, _field) do
    "—"
  end

  defp constructor_names(%{constructors: constructors}) do
    constructors
    |> Enum.map(& &1.name)
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      names -> names
    end
  end

  defp constructor_value(%{constructor: constructor}, field) when is_map(constructor) do
    Map.get(constructor, field) || "—"
  end

  defp constructor_value(_standing, _field) do
    "—"
  end

  defp number(value) when is_float(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  defp number(value) do
    to_string(value)
  end
end
