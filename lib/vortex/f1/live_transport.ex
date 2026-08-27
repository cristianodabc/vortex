defmodule Vortex.F1.LiveTransport do
  @moduledoc """
  Narrow boundary around a provider's live message transport.

  Implementations own third-party connection details and forward lifecycle or
  payload notifications to the configured owner process. Credentials and tokens
  must remain backend-only.
  """

  alias Vortex.F1.Error

  @typedoc "A Vortex-owned stable identifier for one transport connection."
  @type connection_id :: String.t()

  @typedoc "An implementation-specific supervised connection reference."
  @type connection_ref :: term()

  @typedoc "A provider topic selected from application-owned configuration."
  @type topic :: String.t()

  @typedoc "Options required to connect, including the owning process."
  @type connection_options :: keyword()

  @doc "Starts one supervised connection for the supplied stable ID."
  @callback start_connection(connection_id(), connection_options()) ::
              {:ok, connection_ref()} | {:error, Error.t()}

  @doc "Stops a connection and releases its provider resources."
  @callback stop_connection(connection_ref()) :: :ok | {:error, Error.t()}

  @doc "Subscribes an established connection to a bounded set of topics."
  @callback subscribe(connection_ref(), [topic()]) :: :ok | {:error, Error.t()}
end
