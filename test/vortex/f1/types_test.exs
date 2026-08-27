defmodule Vortex.F1.TypesTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Types

  describe "season/1" do
    test "accepts supported integer and string seasons" do
      assert {:ok, 1950} = Types.season(1950)
      assert {:ok, 2026} = Types.season("2026")
    end

    test "rejects seasons outside the supported range" do
      assert {:error, :invalid_season} = Types.season(1949)
      assert {:error, :invalid_season} = Types.season(10_000)
      assert {:error, :invalid_season} = Types.season("latest")
    end
  end

  describe "round/1" do
    test "accepts bounded integer and string rounds" do
      assert {:ok, 1} = Types.round(1)
      assert {:ok, 99} = Types.round("99")
    end

    test "rejects missing and out-of-range rounds" do
      assert {:error, :invalid_round} = Types.round(nil)
      assert {:error, :invalid_round} = Types.round(0)
      assert {:error, :invalid_round} = Types.round(100)
    end
  end

  describe "session_kind/1" do
    test "normalizes only known session kinds" do
      assert {:ok, :race} = Types.session_kind("Race")
      assert {:ok, :qualifying} = Types.session_kind("qualifying")
      assert {:ok, :sprint_shootout} = Types.session_kind("Sprint Shootout")
      assert {:ok, :practice_1} = Types.session_kind(:practice_1)
    end

    test "never creates an atom from an unknown value" do
      value = "provider_kind_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(value)
      end

      assert {:error, :invalid_session_kind} = Types.session_kind(value)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(value)
      end
    end
  end

  describe "display/2" do
    test "uses a neutral fallback for missing values" do
      assert "—" = Types.display(nil)
      assert "Unknown" = Types.display("   ", fallback: "Unknown")
    end

    test "removes control characters, collapses whitespace, and bounds output" do
      value = "  A\n\tvery\u0000  " <> String.duplicate("long ", 30)
      normalized = Types.display(value)

      refute normalized =~ "\n"
      refute normalized =~ "\u0000"
      refute normalized =~ "  "
      assert String.length(normalized) <= 80
    end
  end

  describe "safe_ref/2" do
    test "builds stable selector-safe identifiers" do
      assert "driver-max-verstappen" = Types.safe_ref("Max_Verstappen", :driver)
      assert "constructor-red-bull" = Types.safe_ref(" Red Bull ", :constructor)
      assert "session-1234" = Types.safe_ref(1234, :session)
    end

    test "returns a neutral fallback for missing or unsafe identifiers" do
      assert "driver-unknown" = Types.safe_ref(nil, :driver)
      assert "driver-unknown" = Types.safe_ref("💥", :driver)
      assert String.length(Types.safe_ref(String.duplicate("a", 200), :driver)) <= 71
    end
  end

  describe "team_colour/1" do
    test "accepts exactly six hexadecimal characters" do
      assert "FF8700" = Types.team_colour("ff8700")
      assert "3671C6" = Types.team_colour("3671C6")
    end

    test "uses the neutral color for missing or invalid input" do
      assert Types.neutral_team_colour() == Types.team_colour(nil)
      assert Types.neutral_team_colour() == Types.team_colour("#ff8700")
      assert Types.neutral_team_colour() == Types.team_colour("fff")
      assert Types.neutral_team_colour() == Types.team_colour("zzzzzz")
    end
  end
end
