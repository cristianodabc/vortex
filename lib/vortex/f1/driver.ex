defmodule Vortex.F1.Driver do
  @moduledoc "A normalized driver identity and session-specific team metadata."

  alias Vortex.F1.Types

  @typedoc "A normalized driver safe for use in presentation components."
  @type t :: %__MODULE__{
          ref: Types.driver_ref(),
          number: non_neg_integer() | nil,
          code: String.t(),
          first_name: String.t(),
          last_name: String.t(),
          display_name: String.t(),
          nationality: String.t(),
          team_ref: Types.constructor_ref() | nil,
          team_name: String.t(),
          team_colour: String.t()
        }

  defstruct ref: "driver-unknown",
            number: nil,
            code: "—",
            first_name: "—",
            last_name: "—",
            display_name: "—",
            nationality: "—",
            team_ref: nil,
            team_name: "—",
            team_colour: "737373"
end
