defmodule Vortex.F1.ProviderBehavioursTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.LiveTransport
  alias Vortex.F1.ReferenceProvider
  alias Vortex.F1.ReplayProvider
  alias Vortex.F1.TimingProvider

  test "reference provider exposes only the four read capabilities" do
    assert callbacks(ReferenceProvider) == [
             constructor_standings: 1,
             driver_standings: 1,
             results: 3,
             schedule: 1
           ]
  end

  test "timing provider separates session discovery from reconciliation" do
    assert callbacks(TimingProvider) == [active_session: 0, reconcile: 1]
  end

  test "live transport owns connection lifecycle and subscription" do
    assert callbacks(LiveTransport) == [start_connection: 2, stop_connection: 1, subscribe: 2]
  end

  test "replay provider separates session discovery from timeline loading" do
    assert callbacks(ReplayProvider) == [sessions: 1, timeline: 1]
  end

  defp callbacks(module) do
    module
    |> apply(:behaviour_info, [:callbacks])
    |> Enum.sort()
  end
end
