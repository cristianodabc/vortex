defmodule Vortex.F1.Meeting do
  @moduledoc "A normalized race meeting and its scheduled sessions."

  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @typedoc "A provider-neutral race meeting with ordered normalized sessions."
  @type t :: %__MODULE__{
          id: String.t(),
          season: Types.season() | nil,
          round: Types.round() | nil,
          name: String.t(),
          circuit_name: String.t(),
          locality: String.t(),
          country: String.t(),
          starts_at: DateTime.t() | nil,
          sessions: [Session.t()]
        }

  defstruct id: "meeting-unknown",
            season: nil,
            round: nil,
            name: "—",
            circuit_name: "—",
            locality: "—",
            country: "—",
            starts_at: nil,
            sessions: []
end
