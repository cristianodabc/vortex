defmodule VortexWeb.DashboardHooks do
  @moduledoc """
  Shared LiveView lifecycle hooks for browser-owned dashboard preferences.

  Theme values are presentation preferences only. The hook allowlists every
  client value before it reaches assigns and leaves unknown values unchanged.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  @themes ["system", "light", "dark"]

  @doc "Attaches strict theme event handling to every dashboard LiveView."
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:theme, "system")
      |> attach_hook(:vortex_theme, :handle_event, &handle_theme_event/3)

    {:cont, socket}
  end

  defp handle_theme_event("theme_changed", %{"theme" => theme}, socket)
       when theme in @themes do
    {:halt, assign(socket, :theme, theme)}
  end

  defp handle_theme_event("theme_changed", _params, socket) do
    {:halt, socket}
  end

  defp handle_theme_event(_event, _params, socket) do
    {:cont, socket}
  end
end
