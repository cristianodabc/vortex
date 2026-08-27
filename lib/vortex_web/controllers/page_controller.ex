defmodule VortexWeb.PageController do
  @moduledoc "Redirects the site root to the canonical Live Timing dashboard route."

  use VortexWeb, :controller

  @doc "Redirects a browser request to `/live-timing`."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    redirect(conn, to: ~p"/live-timing")
  end
end
