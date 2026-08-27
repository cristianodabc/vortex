defmodule Vortex.F1.FakeReferenceProvider do
  @moduledoc "A process-backed `ReferenceProvider` fake for deterministic LiveView tests."

  @behaviour Vortex.F1.ReferenceProvider

  alias Vortex.F1.Error

  @doc "Returns a worker child specification for test-owned supervision."
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(responses) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [responses]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc "Starts the fake with an optional map of operation responses."
  @spec start_link(map()) :: Agent.on_start()
  def start_link(responses) do
    Agent.start_link(fn -> responses end, name: __MODULE__)
  end

  @doc "Replaces the response for an exact operation key."
  @spec put(term(), term()) :: :ok
  def put(key, response) do
    Agent.update(__MODULE__, &Map.put(&1, key, response))
  end

  @impl true
  def schedule(season) do
    reply({:schedule, season}, :schedule)
  end

  @impl true
  def results(season, round, kind) do
    reply({:results, season, round, kind}, :results)
  end

  @impl true
  def driver_standings(season) do
    reply({:driver_standings, season}, :driver_standings)
  end

  @impl true
  def constructor_standings(season) do
    reply({:constructor_standings, season}, :constructor_standings)
  end

  defp reply(exact_key, fallback_key) do
    response =
      Agent.get(__MODULE__, fn responses ->
        Map.get(
          responses,
          exact_key,
          Map.get(responses, fallback_key, {:error, Error.new(:unavailable)})
        )
      end)

    if is_function(response, 0), do: response.(), else: response
  end
end
