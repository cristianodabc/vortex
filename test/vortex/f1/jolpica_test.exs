defmodule Vortex.F1.JolpicaTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Error
  alias Vortex.F1.Jolpica
  alias Vortex.F1.Meeting
  alias Vortex.F1.Result

  describe "schedule/2" do
    test "normalizes meetings and their optional sessions" do
      assert {:ok, [%Meeting{} = meeting]} =
               Jolpica.schedule(2024, request_options: request_options("schedule.json"))

      assert meeting.id == "meeting-2024-1"
      assert meeting.name == "Bahrain Grand Prix"
      assert meeting.circuit_name == "Bahrain International Circuit"
      assert meeting.starts_at == ~U[2024-03-02 15:00:00Z]

      assert Enum.map(meeting.sessions, & &1.kind) == [
               :practice_1,
               :practice_2,
               :practice_3,
               :qualifying,
               :race
             ]
    end

    test "follows bounded pagination and combines pages in order" do
      parent = self()

      plug = fn conn ->
        send(parent, {:request, conn.request_path, conn.query_params})

        fixture =
          case conn.query_params["offset"] do
            nil -> "schedule_page_1.json"
            "0" -> "schedule_page_1.json"
            "1" -> "schedule_page_2.json"
          end

        Req.Test.json(conn, fixture(fixture))
      end

      assert {:ok, meetings} =
               Jolpica.schedule(2024, request_options: [plug: plug, retry: false])

      assert Enum.map(meetings, & &1.round) == [1, 2]
      assert_received {:request, "/ergast/f1/2024/races/", %{"limit" => "100", "offset" => "0"}}

      assert_received {:request, "/ergast/f1/2024/races/", %{"limit" => "100", "offset" => "1"}}
    end
  end

  describe "results/4" do
    test "normalizes a completed race classification" do
      assert {:ok, [%Result{} = result]} =
               Jolpica.results(2024, 1, :race, request_options: request_options("results.json"))

      assert result.id == "result-2024-1-race-driver-max-verstappen"
      assert result.position == 1
      assert result.driver.display_name == "Max Verstappen"
      assert result.constructor.ref == "constructor-red-bull"
      assert result.points == 26.0
      assert result.fastest_lap == "1:32.608"
    end

    test "normalizes qualifying phase times and promotes the latest completed phase" do
      assert {:ok, [%Result{} = result]} =
               Jolpica.results(
                 2024,
                 1,
                 :qualifying,
                 request_options: request_options("qualifying.json")
               )

      assert result.time == "1:29.179"
      assert result.q1 == "1:30.031"
      assert result.q2 == "1:29.374"
      assert result.q3 == "1:29.179"
    end
  end

  describe "standings" do
    test "normalizes driver standings" do
      assert {:ok, [%DriverStanding{} = standing]} =
               Jolpica.driver_standings(2024,
                 request_options: request_options("driver_standings.json")
               )

      assert standing.id == "driver-standing-driver-max-verstappen"
      assert standing.position == 1
      assert standing.points == 437.0
      assert standing.wins == 9
    end

    test "normalizes constructor standings" do
      assert {:ok, [%ConstructorStanding{} = standing]} =
               Jolpica.constructor_standings(2024,
                 request_options: request_options("constructor_standings.json")
               )

      assert standing.id == "constructor-standing-constructor-mclaren"
      assert standing.position == 1
      assert standing.points == 666.0
      assert standing.wins == 6
    end
  end

  describe "failure translation" do
    test "returns a sanitized malformed error for invalid JSON" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, File.read!(fixture_path("malformed.json")))
      end

      assert {:error, %Error{kind: :malformed}} =
               Jolpica.schedule(2024, request_options: [plug: plug, retry: false])
    end

    test "translates transport timeouts" do
      plug = fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error, %Error{kind: :timeout}} =
               Jolpica.schedule(2024, request_options: [plug: plug, retry: false])
    end

    test "translates authorization failures without response bodies" do
      for status <- [401, 403] do
        secret = "provider-secret-#{status}"

        assert {:error, %Error{kind: :unauthorized} = error} =
                 Jolpica.schedule(2024,
                   request_options: response_options(status, secret)
                 )

        refute inspect(error) =~ secret
      end
    end

    test "translates not found responses" do
      assert {:error, %Error{kind: :not_found}} =
               Jolpica.schedule(2024, request_options: response_options(404, "missing"))
    end

    test "translates rate limits and bounds Retry-After" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "3")
        |> Plug.Conn.send_resp(429, "slow down")
      end

      assert {:error, %Error{kind: :rate_limited, retry_after_ms: 3_000}} =
               Jolpica.schedule(2024, request_options: [plug: plug, retry: false])
    end

    test "translates upstream server failures" do
      for status <- [500, 502, 503] do
        assert {:error, %Error{kind: :upstream}} =
                 Jolpica.schedule(2024, request_options: response_options(status, "upstream"))
      end
    end
  end

  defp request_options(name) do
    plug = fn conn ->
      assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      assert user_agent =~ ~r/\AVortex\/\d+\.\d+\.\d+\z/
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")

      Req.Test.json(conn, fixture(name))
    end

    [plug: plug, retry: false]
  end

  defp response_options(status, body) do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, status, body)
    end

    [plug: plug, retry: false]
  end

  defp fixture(name) do
    name
    |> fixture_path()
    |> File.read!()
    |> Jason.decode!()
  end

  defp fixture_path(name) do
    Path.expand("../../fixtures/jolpica/#{name}", __DIR__)
  end
end
