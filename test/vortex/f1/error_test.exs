defmodule Vortex.F1.ErrorTest do
  use ExUnit.Case, async: true

  alias Vortex.F1.Error

  test "builds allowlisted presentation-safe messages" do
    secret = "Bearer should-never-reach-the-view"

    error =
      Error.new(:rate_limited,
        source: :jolpica,
        retry_after_ms: 2_000,
        provider_body: secret
      )

    assert %Error{
             kind: :rate_limited,
             message: "The data source is temporarily rate limited.",
             source: :jolpica,
             retry_after_ms: 2_000
           } = error

    refute inspect(error) =~ secret
  end

  test "falls back to unavailable for unknown error categories" do
    assert %Error{kind: :unavailable, message: "Data is temporarily unavailable."} =
             Error.new(:unexpected_provider_value)
  end
end
