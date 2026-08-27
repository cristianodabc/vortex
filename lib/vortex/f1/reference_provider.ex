defmodule Vortex.F1.ReferenceProvider do
  @moduledoc """
  Contract for slower Formula 1 schedule, result, and standings data.

  Implementations must return only Vortex-owned structs and sanitized errors.
  Provider response maps, HTTP client structs, URLs, and bodies must not cross
  this boundary.
  """

  alias Vortex.F1.ConstructorStanding
  alias Vortex.F1.DriverStanding
  alias Vortex.F1.Error
  alias Vortex.F1.Meeting
  alias Vortex.F1.Result
  alias Vortex.F1.Types

  @typedoc "A successful normalized provider result or a sanitized failure."
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @doc "Returns the chronologically ordered race schedule for a season."
  @callback schedule(Types.season()) :: result([Meeting.t()])

  @doc "Returns the ordered classification for a completed session."
  @callback results(Types.season(), Types.round(), Types.session_kind()) ::
              result([Result.t()])

  @doc "Returns driver championship standings for a season."
  @callback driver_standings(Types.season()) :: result([DriverStanding.t()])

  @doc "Returns constructor championship standings for a season."
  @callback constructor_standings(Types.season()) :: result([ConstructorStanding.t()])
end
