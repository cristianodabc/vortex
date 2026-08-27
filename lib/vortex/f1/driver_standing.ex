defmodule Vortex.F1.DriverStanding do
  @moduledoc "A normalized driver championship standing."

  alias Vortex.F1.Constructor
  alias Vortex.F1.Driver

  @typedoc "One normalized driver championship table row."
  @type t :: %__MODULE__{
          id: String.t(),
          position: pos_integer() | nil,
          driver: Driver.t() | nil,
          constructors: [Constructor.t()],
          points: float(),
          wins: non_neg_integer()
        }

  defstruct id: "driver-standing-unknown",
            position: nil,
            driver: nil,
            constructors: [],
            points: 0.0,
            wins: 0
end
