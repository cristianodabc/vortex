defmodule Vortex.F1.OpenF1.Client do
  @moduledoc """
  Performs bounded JSON GET requests against OpenF1's REST API.

  It accepts only decoded JSON lists and returns sanitized Vortex errors. Raw
  response bodies, request URLs, credentials, and transport structs never cross
  this boundary.
  """

  alias Vortex.F1.Error

  @default_timeout_ms 5_000
  @default_retry_delay_ms 250
  @maximum_retry_after_ms 60_000

  @typedoc "A decoded OpenF1 collection or sanitized provider failure."
  @type result :: {:ok, [map()]} | {:error, Error.t()}

  @doc "Fetches one relative OpenF1 collection with optional deterministic request options."
  @spec get(String.t(), keyword()) :: result()
  def get(path, options \\ []) when is_binary(path) do
    started_at = System.monotonic_time()
    result = perform_get(path, options)

    :telemetry.execute(
      [:vortex, :f1, :provider, :request],
      %{duration: System.monotonic_time() - started_at},
      provider_metadata(options, result)
    )

    result
  end

  defp perform_get(path, options) do
    timeout_ms = configured_timeout()

    request =
      Req.new(
        base_url: configured_base_url(),
        headers: [
          {"accept", "application/json"},
          {"user-agent", user_agent()}
        ],
        connect_options: [timeout: timeout_ms],
        receive_timeout: timeout_ms,
        request_timeout: timeout_ms,
        retry: retry_callback(options),
        max_retries: 2,
        retry_log_level: false
      )

    arguments =
      [url: path, params: Keyword.get(options, :params, [])]
      |> Keyword.merge(Keyword.get(options, :request_options, []))

    request
    |> Req.get(arguments)
    |> translate_result()
  rescue
    _exception in [ArgumentError, URI.Error] ->
      {:error, Error.new(:unavailable, source: :open_f1)}
  end

  defp translate_result({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_list(body) do
    if Enum.all?(body, &is_map/1) do
      {:ok, body}
    else
      {:error, Error.new(:schema, source: :open_f1)}
    end
  end

  defp translate_result({:ok, %Req.Response{status: status}}) when status in 200..299 do
    {:error, Error.new(:malformed, source: :open_f1)}
  end

  defp translate_result({:ok, %Req.Response{status: status}}) when status in [401, 403] do
    {:error, Error.new(:unauthorized, source: :open_f1)}
  end

  defp translate_result({:ok, %Req.Response{status: 404}}) do
    {:error, Error.new(:not_found, source: :open_f1)}
  end

  defp translate_result({:ok, %Req.Response{status: 408}}) do
    {:error, Error.new(:timeout, source: :open_f1)}
  end

  defp translate_result({:ok, %Req.Response{status: 429} = response}) do
    {:error,
     Error.new(:rate_limited,
       source: :open_f1,
       retry_after_ms: response_retry_after(response)
     )}
  end

  defp translate_result({:ok, %Req.Response{status: status}}) when status in 500..599 do
    {:error, Error.new(:upstream, source: :open_f1)}
  end

  defp translate_result({:ok, %Req.Response{}}) do
    {:error, Error.new(:upstream, source: :open_f1)}
  end

  defp translate_result({:error, %Req.TransportError{reason: :timeout}}) do
    {:error, Error.new(:timeout, source: :open_f1)}
  end

  defp translate_result({:error, %Jason.DecodeError{}}) do
    {:error, Error.new(:malformed, source: :open_f1)}
  end

  defp translate_result({:error, _reason}) do
    {:error, Error.new(:unavailable, source: :open_f1)}
  end

  defp response_retry_after(response) do
    response
    |> Req.Response.get_retry_after()
    |> case do
      milliseconds when is_integer(milliseconds) ->
        milliseconds
        |> max(0)
        |> min(@maximum_retry_after_ms)

      _missing ->
        nil
    end
  end

  defp retry_callback(options) do
    delay_ms = Keyword.get(options, :retry_delay_ms, @default_retry_delay_ms)
    jitter = Keyword.get(options, :jitter, &default_jitter/0)

    fn request, response_or_exception ->
      retry_decision(request, response_or_exception, delay_ms, jitter)
    end
  end

  defp retry_decision(%Req.Request{method: method}, response, delay_ms, jitter)
       when method in [:get, :head] do
    if transient?(response) do
      {:delay, bounded_retry_delay(response, delay_ms, jitter)}
    else
      false
    end
  end

  defp retry_decision(_request, _response, _delay_ms, _jitter) do
    false
  end

  defp transient?(%Req.Response{status: status})
       when status in [408, 429, 500, 502, 503, 504] do
    true
  end

  defp transient?(%Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed] do
    true
  end

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available] do
    true
  end

  defp transient?(_response_or_exception) do
    false
  end

  defp bounded_retry_delay(%Req.Response{status: status} = response, delay_ms, jitter)
       when status in [429, 503] do
    response
    |> Req.Response.get_retry_after()
    |> case do
      milliseconds when is_integer(milliseconds) -> milliseconds
      _missing -> delay_ms + jitter.()
    end
    |> max(0)
    |> min(@maximum_retry_after_ms)
  end

  defp bounded_retry_delay(_response_or_exception, delay_ms, jitter) do
    delay_ms
    |> Kernel.+(jitter.())
    |> max(0)
    |> min(@maximum_retry_after_ms)
  end

  defp provider_metadata(options, result) do
    result_class = result_class(result)

    %{
      provider: :open_f1,
      operation: normalize_operation(Keyword.get(options, :operation)),
      result: result_class,
      rate_limited: result_class == :rate_limited
    }
  end

  defp result_class({:ok, _body}) do
    :ok
  end

  defp result_class({:error, %Error{kind: kind}}) do
    kind
  end

  defp normalize_operation(operation) when operation in [:replay_sessions, :replay_timeline] do
    operation
  end

  defp normalize_operation(_operation) do
    :timing
  end

  defp configured_base_url do
    :vortex
    |> Application.fetch_env!(:f1)
    |> Keyword.fetch!(:open_f1_rest_url)
  end

  defp configured_timeout do
    :vortex
    |> Application.fetch_env!(:f1)
    |> Keyword.get(:http_timeout_ms, @default_timeout_ms)
  end

  defp user_agent do
    version = :vortex |> Application.spec(:vsn) |> to_string()
    "Vortex/" <> version
  end

  defp default_jitter do
    :rand.uniform(101) - 1
  end
end
