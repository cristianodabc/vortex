defmodule Vortex.F1.TimingProvider do
  @moduledoc """
  Contract for discovering and reconciling the current timing session.

  This boundary supplies coherent normalized state. It does not expose live
  transport concerns or raw provider events.
  """

  alias Vortex.F1.Error
  alias Vortex.F1.RaceProjection
  alias Vortex.F1.Session
  alias Vortex.F1.Types

  @typedoc "The outcome of looking for the current provider session."
  @type active_session_result ::
          {:ok, Session.t()} | {:error, :inactive} | {:error, Error.t()}

  @doc "Finds the current timing session, or reports that no session is active."
  @callback active_session() :: active_session_result()

  @doc "Fetches one coherent current projection for restart or reconnect recovery."
  @callback reconcile(Types.session_key()) ::
              {:ok, RaceProjection.t()} | {:error, Error.t()}
end
