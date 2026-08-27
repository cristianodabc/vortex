defmodule Vortex.F1.ModelsTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Constructor
  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.Driver
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Error
  alias Vortex.F1.Meeting
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Resource
  alias Vortex.F1.Result
  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow

  @public_structs [
    Meeting,
    Session,
    Driver,
    Constructor,
    Result,
    DriverStanding,
    ConstructorStanding,
    TimingRow,
    RaceProjection,
    Resource,
    Error
  ]

  test "every public domain struct publishes a t type" do
    for module <- @public_structs do
      assert {:ok, types} = Code.Typespec.fetch_types(module)

      assert Enum.any?(types, fn
               {:type, {name, _, _}} -> name == :t
               _other -> false
             end),
             "expected #{inspect(module)} to define @type t"
    end
  end

  test "struct defaults are presentation-safe and contain no provider maps" do
    assert %Meeting{sessions: []} = %Meeting{}
    assert %Driver{team_colour: "737373"} = %Driver{}
    assert %Constructor{colour: "737373"} = %Constructor{}
    assert %Result{}.points == 0.0
    assert %DriverStanding{wins: 0} = %DriverStanding{}
    assert %DriverStanding{}.points == 0.0
    assert %ConstructorStanding{wins: 0} = %ConstructorStanding{}
    assert %ConstructorStanding{}.points == 0.0
    assert %TimingRow{team_colour: "737373", tyre: :unknown} = %TimingRow{}
    assert %RaceProjection{rows: [], cursors: %{}} = %RaceProjection{}
    assert %Resource{freshness: :fresh} = %Resource{}
  end
end
