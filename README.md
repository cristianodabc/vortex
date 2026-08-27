# Vortex

Vortex is a minimalist, full-page Formula 1 dashboard built with Phoenix LiveView for personal, non-commercial fan use. It presents schedules, completed session results, championship standings, and a bounded current-race timing projection without sending provider credentials or raw feeds to browsers.

Vortex is an unofficial fan project. It is not affiliated with, endorsed by, or sponsored by Formula 1, the FIA, Formula One Management, or their partners. Formula 1 and related marks belong to their respective owners.

## Current capabilities

- Schedule with completed, in-progress, and upcoming weekend labels
- Race, qualifying, and sprint classifications selected from the season calendar
- Driver and constructor standings
- Per-viewer play, pause, step, scrub, restart, and speed controls for bounded OpenF1 race replay from 2023 onward
- Light, dark, and system themes
- Restrained official provider team-color identity accents with neutral fallbacks
- Explicit loading, empty, stale, degraded, rate-limited, and unavailable states
- In-memory reference caching with stale-while-refresh behavior

Historical schedule, results, and standings data use [Jolpica F1](https://github.com/jolpica/jolpica-f1). Historical timing playback uses [OpenF1](https://openf1.org/) sessions, drivers, position, intervals, laps, stints, and pit data. OpenF1's free access is historical-only, while real-time access requires a paid plan. The historical dashboard boots and remains usable without live credentials.

Vortex does not persist race snapshots or raw telemetry. Current-race state and bounded historical replay timelines are intentionally held only in supervised process memory and are rebuilt or reloaded after a node restart. Replay controls belong to each viewer and never alter the shared live projection.

## Requirements

- Elixir and Erlang versions compatible with `mix.exs`
- A supported Node.js installation for asset tooling

## Setup

```sh
mix setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

Copy `.env.example` values into your runtime environment when enabling optional capabilities. Provider credentials must remain server-side and must never be committed or exposed to LiveView assigns.

## Configuration

The default development configuration uses Jolpica for reference data. Important runtime capabilities include:

- Reference provider base URL, identifying user agent, timeouts, and cache limits
- Historical and live capability flags
- Optional OpenF1 client credentials for personal live access
- Current-state stale thresholds and bounded publish cadence

See `.env.example` and `config/runtime.exs` for the supported environment variables. Keep live mode disabled unless the broker and reconciliation contract has been verified with authorized credentials.

## Data freshness and failure behavior

Reference responses are normalized at the provider boundary and cached as coherent resources. A resource reports its source, freshness, and local version. When a refresh fails, Vortex may continue showing the last-known resource with a stale or degraded label; it never presents replay, resynchronization, or provider failure as live data.

The APIs are community-operated services with their own availability and rate limits. Vortex uses one backend-owned live connection for all viewers when live mode is enabled and does not create an upstream feed per browser.

## Data terms and attribution

- Jolpica data is available for non-commercial use under CC BY-NC-SA 4.0. Review the current [Jolpica terms](https://github.com/jolpica/jolpica-f1/blob/main/TERMS.md) and [API documentation](https://github.com/jolpica/jolpica-f1/tree/main/docs) before hosting.
- OpenF1 is intended for education, research, personal projects, and non-commercial fan engagement under CC BY-NC-SA 4.0. Review its current [access terms and documentation](https://openf1.org/) before enabling it.
- Provider data licenses do not grant rights to Formula 1 trademarks, photography, broadcast footage, team logos, or other third-party assets.

The UI uses original Vortex text/geometry and system icons. Team logos are intentionally absent: OpenF1 does not provide them, and data access does not grant trademark or artwork rights. Do not add official logos, photography, circuit art, broadcast graphics, or copied dashboard assets without separately verifying and documenting permission. Provider-supplied official team colors are used only as 3 px identity bars paired with text labels; missing colors stay neutral.

## License

Vortex's source code is available under the [MIT License](LICENSE). Provider data and third-party Formula 1-related rights remain governed separately by their respective licenses and terms.

## Architecture

The historical path uses documented provider behaviours, normalized structs, `Req`, one supervised reference cache, and a bounded replay store. The live path uses a small OTP subsystem: one canonical current-race state process and, when enabled in a future verified transport slice, one feed owner responsible for authentication, connection health, coalescing, retries, and reconciliation.

GenStage, Broadway, Ecto, ETS, persistent snapshots, charts, and per-viewer provider connections are deliberately deferred until a measured requirement justifies them. Historical playback reuses bounded provider events in memory; it is not a durable replay archive.

Architecture decisions live in `docs/adr/`.

## Verification

```sh
mix precommit
```

The automated suite uses injected provider fakes and deterministic fixtures; it does not depend on live network access.
