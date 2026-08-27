import Config

parse_positive_integer = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {integer, ""} when integer > 0 ->
          integer

        _other ->
          raise "#{name} must be a positive integer"
      end
  end
end

parse_http_url = fn name, default ->
  value = System.get_env(name, default)
  uri = URI.parse(value)

  if uri.scheme in ["http", "https"] and is_binary(uri.host) do
    value
  else
    raise "#{name} must be an absolute HTTP(S) URL"
  end
end

live_enabled =
  System.get_env("VORTEX_LIVE_ENABLED", "false")
  |> String.downcase()
  |> then(&(&1 in ["1", "true", "yes", "on"]))

open_f1_username = System.get_env("OPENF1_USERNAME")
open_f1_password = System.get_env("OPENF1_PASSWORD")

live_configured =
  live_enabled and is_binary(open_f1_username) and open_f1_username != "" and
    is_binary(open_f1_password) and open_f1_password != ""

config :vortex, :f1,
  live_enabled: live_enabled,
  live_configured: live_configured,
  mode: if(live_configured, do: :live, else: :historical),
  jolpica_base_url: parse_http_url.("JOLPICA_BASE_URL", "https://api.jolpi.ca/ergast/f1"),
  open_f1_rest_url: parse_http_url.("OPENF1_REST_URL", "https://api.openf1.org/v1"),
  open_f1_token_url: parse_http_url.("OPENF1_TOKEN_URL", "https://api.openf1.org/token"),
  open_f1_mqtt_host: System.get_env("OPENF1_MQTT_HOST", "mqtt.openf1.org"),
  open_f1_mqtt_port: parse_positive_integer.("OPENF1_MQTT_PORT", 8883),
  open_f1_username: if(live_configured, do: open_f1_username, else: nil),
  open_f1_password: if(live_configured, do: open_f1_password, else: nil),
  http_timeout_ms: parse_positive_integer.("VORTEX_HTTP_TIMEOUT_MS", 5_000),
  publish_cadence_ms: parse_positive_integer.("VORTEX_PUBLISH_CADENCE_MS", 500),
  reconnect_max_ms: parse_positive_integer.("VORTEX_RECONNECT_MAX_MS", 30_000),
  reference_cache_max_entries: parse_positive_integer.("VORTEX_REFERENCE_CACHE_MAX_ENTRIES", 256),
  reference_cache_failure_retry_ms:
    parse_positive_integer.("VORTEX_REFERENCE_CACHE_FAILURE_RETRY_MS", 1_000),
  schedule_ttl_ms: parse_positive_integer.("VORTEX_SCHEDULE_TTL_MS", :timer.minutes(15)),
  standings_ttl_ms: parse_positive_integer.("VORTEX_STANDINGS_TTL_MS", :timer.minutes(5)),
  current_results_ttl_ms:
    parse_positive_integer.("VORTEX_CURRENT_RESULTS_TTL_MS", :timer.hours(24))

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/vortex start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :vortex, VortexWeb.Endpoint, server: true
end

config :vortex, VortexWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :vortex, VortexWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/vortex_web/router\.ex$"E,
        ~r"lib/vortex_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :vortex, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :vortex, VortexWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :vortex, VortexWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :vortex, VortexWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :vortex, Vortex.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
