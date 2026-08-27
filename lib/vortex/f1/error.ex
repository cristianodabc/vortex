defmodule Vortex.F1.Error do
  @moduledoc """
  A provider-neutral failure safe to expose at the Vortex context boundary.

  Raw response bodies, URLs, request structs, credentials, and exception details
  are intentionally not fields on this struct.
  """

  alias Vortex.F1.Types

  @messages %{
    timeout: "The data source took too long to respond.",
    unauthorized: "The data source could not authorize this request.",
    not_found: "The requested data is not available.",
    rate_limited: "The data source is temporarily rate limited.",
    upstream: "The data source returned an unexpected response.",
    malformed: "The data source returned unreadable data.",
    schema: "The data source returned data Vortex could not understand.",
    unavailable: "Data is temporarily unavailable."
  }

  @typedoc "A sanitized provider-neutral failure safe for presentation logic."
  @type t :: %__MODULE__{
          kind: Types.provider_error_kind(),
          message: String.t(),
          source: Types.source() | nil,
          retry_after_ms: non_neg_integer() | nil
        }

  defstruct kind: :unavailable,
            message: "Data is temporarily unavailable.",
            source: nil,
            retry_after_ms: nil

  @doc """
  Builds a sanitized error from an allowlisted category.

  Unknown categories become `:unavailable`. Unrecognized options are ignored so
  provider details cannot accidentally cross the domain boundary.
  """
  @spec new(term(), keyword()) :: t()
  def new(kind, options \\ []) do
    normalized_kind = if Map.has_key?(@messages, kind), do: kind, else: :unavailable

    %__MODULE__{
      kind: normalized_kind,
      message: Map.fetch!(@messages, normalized_kind),
      source: normalize_source(Keyword.get(options, :source)),
      retry_after_ms: normalize_retry_after(Keyword.get(options, :retry_after_ms))
    }
  end

  defp normalize_source(source) when source in [:jolpica, :open_f1, :fixture] do
    source
  end

  defp normalize_source(_source) do
    nil
  end

  defp normalize_retry_after(milliseconds)
       when is_integer(milliseconds) and milliseconds >= 0 do
    milliseconds
  end

  defp normalize_retry_after(_milliseconds) do
    nil
  end
end
