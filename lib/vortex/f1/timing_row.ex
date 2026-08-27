defmodule Vortex.F1.TimingRow do
  @moduledoc "A presentation-ready row in the current timing tower."

  alias Vortex.F1.Driver

  @type tyre :: :soft | :medium | :hard | :intermediate | :wet | :unknown
  @type pit_state :: :track | :pit_in | :pit | :pit_out | :unknown

  @typedoc "One normalized row in the current timing order."
  @type t :: %__MODULE__{
          id: String.t(),
          position: pos_integer() | nil,
          driver: Driver.t() | nil,
          gap: String.t(),
          interval: String.t(),
          last_lap: String.t(),
          best_lap: String.t(),
          tyre: tyre(),
          tyre_age: non_neg_integer() | nil,
          pit_state: pit_state(),
          status: String.t(),
          team_colour: String.t()
        }

  defstruct id: "timing-row-unknown",
            position: nil,
            driver: nil,
            gap: "—",
            interval: "—",
            last_lap: "—",
            best_lap: "—",
            tyre: :unknown,
            tyre_age: nil,
            pit_state: :unknown,
            status: "—",
            team_colour: "737373"
end
