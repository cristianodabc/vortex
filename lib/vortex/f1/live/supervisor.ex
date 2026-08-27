defmodule Vortex.F1.Live.Supervisor do
  @moduledoc """
  Supervises canonical current-race state independently of optional transport.

  The state owner always boots, including historical-only mode. An eventual
  live feed is a dependent child and must never be started without validated
  runtime capability.
  """

  use Supervisor

  @doc "Starts the live subsystem supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    Supervisor.init([Vortex.F1.Live.RaceState], strategy: :rest_for_one)
  end
end
