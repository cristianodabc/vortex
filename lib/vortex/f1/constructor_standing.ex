defmodule Vortex.F1.ConstructorStanding do
  @moduledoc "A normalized constructor championship standing."

  alias Vortex.F1.Constructor

  @typedoc "One normalized constructor championship table row."
  @type t :: %__MODULE__{
          id: String.t(),
          position: pos_integer() | nil,
          constructor: Constructor.t() | nil,
          points: float(),
          wins: non_neg_integer()
        }

  defstruct id: "constructor-standing-unknown",
            position: nil,
            constructor: nil,
            points: 0.0,
            wins: 0
end
