defmodule Vortex.F1.Result do
  @moduledoc "A normalized classification row for a completed session."

  alias Vortex.F1.Constructor
  alias Vortex.F1.Driver

  @typedoc "One normalized classification row for a completed session."
  @type t :: %__MODULE__{
          id: String.t(),
          position: pos_integer() | nil,
          driver: Driver.t() | nil,
          constructor: Constructor.t() | nil,
          grid: non_neg_integer() | nil,
          laps: non_neg_integer() | nil,
          time: String.t(),
          q1: String.t() | nil,
          q2: String.t() | nil,
          q3: String.t() | nil,
          gap: String.t(),
          status: String.t(),
          points: float(),
          fastest_lap: String.t() | nil
        }

  defstruct id: "result-unknown",
            position: nil,
            driver: nil,
            constructor: nil,
            grid: nil,
            laps: nil,
            time: "—",
            q1: nil,
            q2: nil,
            q3: nil,
            gap: "—",
            status: "—",
            points: 0.0,
            fastest_lap: nil
end
