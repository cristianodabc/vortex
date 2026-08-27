defmodule Vortex.F1.Cache do
  @moduledoc """
  Public facade for the process-owned reference-data cache.

  Fresh entries return immediately. Stale entries return last-known data while
  one supervised background loader revalidates them. Concurrent cold misses for
  the same key wait for one shared loader.
  """

  alias Vortex.F1.Cache.Server
  alias Vortex.F1.Error
  alias Vortex.F1.Resource

  @typedoc "A bounded identity for one cached reference-data request."
  @type key :: term()

  @typedoc "A function that returns normalized data without raising provider details."
  @type loader(value) :: (-> {:ok, value} | {:error, Error.t()})

  @doc "Fetches a key from the application cache."
  @spec fetch(key(), keyword(), loader(value)) ::
          {:ok, Resource.t(value)} | {:error, Error.t()}
        when value: term()
  def fetch(key, options, loader) do
    fetch(Server, key, options, loader)
  end

  @doc """
  Fetches a key from a specific cache server.

  Options require a positive `:ttl_ms` and a Vortex provider `:source`.
  """
  @spec fetch(GenServer.server(), key(), keyword(), loader(value)) ::
          {:ok, Resource.t(value)} | {:error, Error.t()}
        when value: term()
  def fetch(server, key, options, loader) when is_function(loader, 0) do
    with {:ok, ttl_ms} <- fetch_ttl(options),
         {:ok, source} <- fetch_source(options) do
      GenServer.call(server, {:fetch, key, ttl_ms, source, loader}, :infinity)
    end
  end

  defp fetch_ttl(options) do
    case Keyword.fetch(options, :ttl_ms) do
      {:ok, :infinity} ->
        {:ok, :infinity}

      {:ok, ttl_ms} when is_integer(ttl_ms) and ttl_ms > 0 ->
        {:ok, ttl_ms}

      _invalid ->
        {:error, Error.new(:schema)}
    end
  end

  defp fetch_source(options) do
    case Keyword.fetch(options, :source) do
      {:ok, source} when source in [:jolpica, :open_f1, :fixture] ->
        {:ok, source}

      _invalid ->
        {:error, Error.new(:schema)}
    end
  end
end
