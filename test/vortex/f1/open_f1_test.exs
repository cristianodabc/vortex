defmodule Vortex.F1.OpenF1Test do
  use ExUnit.Case, async: true

  alias Vortex.F1.Error
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.OpenF1
  alias Vortex.F1.Session

  test "discovers historical race sessions from 2023 onward" do
    plug = fn conn ->
      send(self(), {:query, conn.query_params})

      Req.Test.json(conn, [
        %{
          "session_key" => 9636,
          "session_name" => "Race",
          "date_start" => "2026-08-23T13:00:00+00:00",
          "date_end" => "2026-08-23T15:00:00+00:00",
          "country_name" => "Belgium"
        }
      ])
    end

    assert {:ok, [%Session{} = session]} =
             OpenF1.sessions(2026, request_options: [plug: plug, retry: false])

    assert session.key == 9636
    assert session.name == "Belgium · Race"
    assert session.starts_at == ~U[2026-08-23 13:00:00Z]
    assert {:error, %Error{kind: :not_found}} = OpenF1.sessions(2022)
  end

  test "normalizes a bounded playback timeline with official team colors" do
    plug = fn conn ->
      Req.Test.json(conn, response_for(conn.request_path))
    end

    assert {:ok, %ReplayTimeline{} = timeline} =
             OpenF1.timeline(9636, request_options: [plug: plug, retry: false])

    projection = ReplayTimeline.project(timeline, timeline.event_count)
    assert projection.status == :replay
    assert projection.source == :open_f1

    assert [row] = projection.rows
    assert row.position == 1
    assert row.driver.display_name == "Lando Norris"
    assert row.driver.team_name == "McLaren"
    assert row.team_colour == "FF8000"
    assert row.interval == "+1.234"
    assert row.last_lap == "1:31.456"
    assert row.best_lap == "1:31.456"
    assert row.tyre == :soft
    assert row.tyre_age == 2
    assert row.pit_state == :pit
  end

  test "sanitizes provider and malformed-session failures" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 429, "provider-secret") end

    assert {:error, %Error{kind: :rate_limited} = error} =
             OpenF1.sessions(2026, request_options: [plug: plug, retry: false])

    refute inspect(error) =~ "provider-secret"
    assert {:error, %Error{kind: :not_found}} = OpenF1.timeline("latest")
  end

  defp response_for("/v1/sessions") do
    [
      %{
        "session_key" => 9636,
        "session_name" => "Race",
        "date_start" => "2026-08-23T13:00:00+00:00",
        "date_end" => "2026-08-23T15:00:00+00:00",
        "country_name" => "Belgium"
      }
    ]
  end

  defp response_for("/v1/drivers") do
    [
      %{
        "session_key" => 9636,
        "driver_number" => 4,
        "name_acronym" => "NOR",
        "first_name" => "Lando",
        "last_name" => "Norris",
        "full_name" => "Lando Norris",
        "team_name" => "McLaren",
        "team_colour" => "FF8000"
      }
    ]
  end

  defp response_for("/v1/position") do
    [
      %{
        "session_key" => 9636,
        "driver_number" => 4,
        "date" => "2026-08-23T13:00:02+00:00",
        "position" => 1
      }
    ]
  end

  defp response_for("/v1/intervals") do
    [
      %{
        "session_key" => 9636,
        "driver_number" => 4,
        "date" => "2026-08-23T13:01:00+00:00",
        "gap_to_leader" => nil,
        "interval" => 1.234
      }
    ]
  end

  defp response_for("/v1/laps") do
    [
      %{
        "session_key" => 9636,
        "driver_number" => 4,
        "date_start" => "2026-08-23T13:00:10+00:00",
        "lap_duration" => 91.456,
        "lap_number" => 1,
        "is_pit_out_lap" => false
      }
    ]
  end

  defp response_for("/v1/stints") do
    [
      %{
        "session_key" => 9636,
        "driver_number" => 4,
        "compound" => "SOFT",
        "lap_start" => 1,
        "tyre_age_at_start" => 2
      }
    ]
  end

  defp response_for("/v1/pit") do
    [
      %{
        "session_key" => 9636,
        "driver_number" => 4,
        "date" => "2026-08-23T14:00:00+00:00",
        "lap_number" => 24
      }
    ]
  end
end
