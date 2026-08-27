defmodule Vortex.ApplicationTest do
  use ExUnit.Case, async: true

  test "boots in historical-only mode without a database or live provider process" do
    f1_config = Application.fetch_env!(:vortex, :f1)
    children = Supervisor.which_children(Vortex.Supervisor)

    assert f1_config[:mode] == :historical
    refute f1_config[:live_configured]
    refute Code.ensure_loaded?(Vortex.Repo)

    assert Process.whereis(Vortex.PubSub)
    assert Process.whereis(Vortex.F1.TaskSupervisor)
    assert Process.whereis(Vortex.F1.Cache.Server)
    assert Process.whereis(Vortex.F1.Live.ReplayStore)
    assert Process.whereis(Vortex.F1.Live.RaceState)
    assert Process.whereis(VortexWeb.Endpoint)

    refute Enum.any?(children, fn {_id, _pid, _type, modules} ->
             Enum.any?(modules, &provider_module?/1)
           end)
  end

  defp provider_module?(module) do
    module in [
      Vortex.F1.Jolpica,
      Vortex.F1.OpenF1,
      Vortex.F1.Live.LiveFeed
    ]
  end
end
