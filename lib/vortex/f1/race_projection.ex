defmodule Vortex.F1.RaceProjection do
  @moduledoc """
  The coherent, current-only race projection exposed to Live Timing.

  It contains no prior snapshots, replay log, or raw telemetry series.
  """

  alias Vortex.F1.Session
  alias Vortex.F1.TimingRow
  alias Vortex.F1.Types

  @type cursor_key :: {String.t(), String.t()}
  @type cursor :: non_neg_integer()

  @typedoc "The complete bounded projection for one current session version."
  @type t :: %__MODULE__{
          session_key: Types.session_key() | nil,
          generation: Types.generation(),
          sequence: Types.sequence(),
          captured_at: DateTime.t() | nil,
          stale_since: DateTime.t() | nil,
          status: Types.status(),
          source: Types.source() | nil,
          rows: [TimingRow.t()],
          session: Session.t() | nil,
          cursors: %{optional(cursor_key()) => cursor()}
        }

  defstruct session_key: nil,
            generation: 0,
            sequence: 0,
            captured_at: nil,
            stale_since: nil,
            status: :inactive,
            source: nil,
            rows: [],
            session: nil,
            cursors: %{}
end
