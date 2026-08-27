defmodule VortexWeb.Telemetry do
  @moduledoc "Supervises Vortex's safe VM, Phoenix, provider, timing, and replay metrics."

  use Supervisor
  import Telemetry.Metrics

  @doc "Starts the telemetry supervisor."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Returns the metrics emitted by Phoenix and Vortex's bounded F1 subsystems."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Vortex F1 Metrics
      sum("vortex.f1.race_state.batch.accepted", tags: [:status]),
      sum("vortex.f1.race_state.batch.malformed", tags: [:status]),
      sum("vortex.f1.race_state.batch.duplicate", tags: [:status]),
      sum("vortex.f1.race_state.batch.older", tags: [:status]),
      sum("vortex.f1.race_state.batch.coalesced", tags: [:status]),
      counter("vortex.f1.race_state.commit.count", tags: [:source, :status]),
      last_value("vortex.f1.race_state.commit.mailbox_length", tags: [:status]),
      counter("vortex.f1.race_state.publish.count", tags: [:source, :status]),
      counter("vortex.f1.replay_store.operation.count", tags: [:operation]),
      counter("vortex.f1.replay.tick.count", tags: [:source, :speed]),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {VortexWeb, :count_users, []}
    ]
  end
end
