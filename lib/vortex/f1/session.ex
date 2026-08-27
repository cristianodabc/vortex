defmodule Vortex.F1.Session do
  @moduledoc "A normalized Formula 1 session within a race meeting."

  alias Vortex.F1.Types

  @typedoc "A provider-neutral scheduled or active Formula 1 session."
  @type t :: %__MODULE__{
          id: String.t(),
          key: Types.session_key() | nil,
          kind: Types.session_kind() | nil,
          name: String.t(),
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          status: Types.status()
        }

  defstruct id: "session-unknown",
            key: nil,
            kind: nil,
            name: "—",
            starts_at: nil,
            ends_at: nil,
            status: :inactive
end
