defmodule VortexWeb.DashboardComponents do
  @moduledoc """
  Stateless components for Vortex's shared full-viewport dashboard frame.

  The shell owns navigation, restrained theme controls, and attribution while
  each focused LiveView owns only its filters and primary content panel.
  """

  use VortexWeb, :html

  @pages [:live_timing, :schedule, :results, :driver_standings, :constructor_standings]
  @themes ["system", "light", "dark"]

  attr :active_page, :atom, required: true, values: @pages
  attr :theme, :string, default: "system", values: @themes
  attr :mode_label, :string, default: "Historical data"
  slot :filters
  slot :inner_block, required: true

  @doc "Renders the edge-to-edge dashboard shell shared by every Vortex LiveView."
  @spec dashboard_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_shell(assigns) do
    ~H"""
    <div
      id="vortex-dashboard"
      class="vortex-dashboard"
      data-theme-preference={@theme}
      phx-hook="ThemeSync"
    >
      <header id="dashboard-header" class="dashboard-header">
        <div class="dashboard-brand">
          <span id="vortex-mark" aria-hidden="true">V</span>
          <div>
            <p id="vortex-wordmark">Vortex</p>
            <p id="session-summary">{@mode_label}</p>
          </div>
        </div>

        <.theme_switcher theme={@theme} />
      </header>

      <.dashboard_nav active_page={@active_page} />

      <div id="dashboard-filters" class="dashboard-filters">
        {render_slot(@filters)}
      </div>

      <main id="dashboard-main" class="dashboard-main">
        {render_slot(@inner_block)}
      </main>

      <footer id="vortex-attribution" class="dashboard-footer">
        <p>Unofficial fan project. Not affiliated with Formula 1, the FIA, or their partners.</p>
        <p class="dashboard-footer-links">
          Data: <a id="attribution-jolpica" href="https://github.com/jolpica/jolpica-f1">Jolpica</a>
          <span aria-hidden="true">·</span>
          <a id="attribution-openf1" href="https://openf1.org/">OpenF1</a>
          <span aria-hidden="true">·</span>
          <a
            id="attribution-terms"
            href="https://github.com/jolpica/jolpica-f1/blob/main/TERMS.md"
          >
            Data terms
          </a>
        </p>
      </footer>
    </div>
    """
  end

  attr :active_page, :atom, required: true, values: @pages

  @doc "Renders route navigation with a non-color current-page indicator."
  @spec dashboard_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_nav(assigns) do
    ~H"""
    <nav id="dashboard-nav" class="dashboard-nav" aria-label="Dashboard views">
      <.nav_link
        id="nav-live-timing"
        label="Live timing"
        path={~p"/live-timing"}
        active={@active_page == :live_timing}
      />
      <.nav_link
        id="nav-schedule"
        label="Schedule"
        path={~p"/schedule"}
        active={@active_page == :schedule}
      />
      <.nav_link
        id="nav-results"
        label="Results"
        path={~p"/results"}
        active={@active_page == :results}
      />
      <.nav_link
        id="nav-driver-standings"
        label="Drivers"
        path={~p"/standings/drivers"}
        active={@active_page == :driver_standings}
      />
      <.nav_link
        id="nav-constructor-standings"
        label="Constructors"
        path={~p"/standings/constructors"}
        active={@active_page == :constructor_standings}
      />
    </nav>
    """
  end

  attr :theme, :string, required: true, values: @themes

  @doc "Renders the system, light, and dark theme controls."
  @spec theme_switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_switcher(assigns) do
    options = [
      {"system", "System theme", "hero-computer-desktop"},
      {"light", "Light theme", "hero-sun"},
      {"dark", "Dark theme", "hero-moon"}
    ]

    assigns = assign(assigns, :options, options)

    ~H"""
    <div id="theme-switcher" class="theme-switcher" role="group" aria-label="Color theme">
      <button
        :for={{theme, label, icon} <- @options}
        id={"theme-#{theme}"}
        type="button"
        class="theme-option"
        aria-label={label}
        aria-pressed={to_string(@theme == theme)}
        title={label}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
      >
        <.icon name={icon} class="theme-icon" />
        <span class="sr-only">{label}</span>
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :path, :string, required: true
  attr :active, :boolean, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@path}
      class={["dashboard-nav-link", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      {@label}
    </.link>
    """
  end
end
