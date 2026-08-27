# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :vortex,
  generators: [timestamp_type: :utc_datetime]

config :vortex, :f1,
  live_enabled: false,
  live_configured: false,
  mode: :historical,
  reference_provider: Vortex.F1.Jolpica,
  reference_source: :jolpica,
  timing_provider: nil,
  replay_provider: Vortex.F1.OpenF1,
  live_transport: nil,
  jolpica_base_url: "https://api.jolpi.ca/ergast/f1",
  open_f1_rest_url: "https://api.openf1.org/v1",
  open_f1_token_url: "https://api.openf1.org/token",
  open_f1_mqtt_host: "mqtt.openf1.org",
  open_f1_mqtt_port: 8883,
  http_timeout_ms: 5_000,
  publish_cadence_ms: 500,
  reconnect_max_ms: 30_000,
  reference_cache_max_entries: 256,
  reference_cache_failure_retry_ms: 1_000,
  schedule_ttl_ms: :timer.minutes(15),
  standings_ttl_ms: :timer.minutes(5),
  current_results_ttl_ms: :timer.hours(24)

# Configure the endpoint
config :vortex, VortexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: VortexWeb.ErrorHTML, json: VortexWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Vortex.PubSub,
  live_view: [signing_salt: "smyf5uZj"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :vortex, Vortex.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  vortex: [
    args:
      ~w(js/app.js js/theme_bootstrap.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  vortex: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
