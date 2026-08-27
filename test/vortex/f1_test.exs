defmodule Vortex.F1Test do
  use ExUnit.Case, async: false

  alias Vortex.F1
  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Error
  alias Vortex.F1.FakeReferenceProvider
  alias Vortex.F1.Meeting
  alias Vortex.F1.Resource
  alias Vortex.F1.Result

  setup do
    original = Application.fetch_env!(:vortex, :f1)

    start_supervised!(
      {FakeReferenceProvider,
       %{
         schedule: {:ok, [%Meeting{season: 2091, round: 1}]},
         results: {:ok, [%Result{id: "result-test"}]},
         driver_standings: {:ok, [%DriverStanding{id: "driver-standing-test"}]},
         constructor_standings: {:ok, [%ConstructorStanding{id: "constructor-standing-test"}]}
       }}
    )

    configured =
      original
      |> Keyword.put(:reference_provider, FakeReferenceProvider)
      |> Keyword.put(:reference_source, :fixture)

    Application.put_env(:vortex, :f1, configured)

    on_exit(fn ->
      Application.put_env(:vortex, :f1, original)
    end)

    :ok
  end

  test "reference APIs return normalized resources through the central context" do
    assert {:ok, %Resource{source: :fixture, value: [%Meeting{}]}} = F1.schedule(2091)

    assert {:ok, %Resource{source: :fixture, value: [%Result{}]}} =
             F1.results(2091, 1, :race)

    assert {:ok, %Resource{source: :fixture, value: [%DriverStanding{}]}} =
             F1.driver_standings(2091)

    assert {:ok, %Resource{source: :fixture, value: [%ConstructorStanding{}]}} =
             F1.constructor_standings(2091)
  end

  test "invalid public parameters fail before a provider request" do
    assert {:error, %Error{kind: :not_found}} = F1.schedule("latest")
    assert {:error, %Error{kind: :not_found}} = F1.results(2091, 0, :race)
    assert {:error, %Error{kind: :not_found}} = F1.results(2091, 1, "unknown")
  end
end
