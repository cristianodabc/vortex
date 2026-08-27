defmodule Vortex.F1.Resource do
  @moduledoc "Normalized data paired with source and cache-freshness metadata."

  alias Vortex.F1.Types

  @typedoc "Normalized data plus provider, version, and cache-freshness metadata."
  @type t(value) :: %__MODULE__{
          value: value,
          source: Types.source() | nil,
          fetched_at: DateTime.t() | nil,
          fresh_until: DateTime.t() | nil,
          freshness: Types.freshness(),
          stale_reason: String.t() | nil,
          version: non_neg_integer()
        }

  defstruct value: nil,
            source: nil,
            fetched_at: nil,
            fresh_until: nil,
            freshness: :fresh,
            stale_reason: nil,
            version: 0
end
