defmodule Vortex.F1.Constructor do
  @moduledoc "A normalized Formula 1 constructor identity."

  alias Vortex.F1.Types

  @typedoc "A normalized constructor safe for use in presentation components."
  @type t :: %__MODULE__{
          ref: Types.constructor_ref(),
          name: String.t(),
          nationality: String.t(),
          colour: String.t()
        }

  defstruct ref: "constructor-unknown",
            name: "—",
            nationality: "—",
            colour: "737373"
end
