defmodule Vortex.F1.ReplayProvider do
  @moduledoc "Contract for historical timing-session discovery and bounded event playback."

  alias Vortex.F1.Error
  alias Vortex.F1.Live.ReplayTimeline
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @doc "Lists historical race sessions available for one supported season."
  @callback sessions(Types.season()) :: {:ok, [Session.t()]} | {:error, Error.t()}

  @doc "Loads one normalized immutable timing timeline by provider session key."
  @callback timeline(Types.session_key()) ::
              {:ok, ReplayTimeline.t()} | {:error, Error.t()}
end
