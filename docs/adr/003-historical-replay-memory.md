# ADR-003: Keep historical replay bounded and in memory

## Status

Accepted on 2026-08-27.

## Context

Vortex needs playback controls for completed OpenF1 race sessions without turning a personal fan dashboard into a telemetry archive. Current live state has a different lifecycle and must not be mutated by historical viewers. Browser count must not multiply provider downloads, while one viewer's pause, scrub, or speed change must not affect another viewer.

Periodic projection snapshots would duplicate most timing rows, complicate invalidation, and imply a durable recording contract the project does not need. Loading a complete provider timeline independently for every LiveView would waste bandwidth and memory.

## Decision

`ReplayStore` coalesces one supervised provider load per session and retains a small least-recently-used set of immutable normalized event timelines. Timelines have TTL and event-count limits and contain only timing-tower topics. They do not contain raw car telemetry, provider payloads, credentials, or periodic projections.

Each `LiveTimingLive` owns only its selected session, cursor, playback speed, timer generation, and current reconstructed projection. Play, pause, step, scrub, restart, and speed events never call `RaceState`. Stale timer messages are rejected by generation. The pure reducer reconstructs the current cursor from bounded events, so no replay snapshots are retained.

OpenF1 historical access is limited to completed race sessions from 2023 onward. A node restart intentionally clears replay timelines; the next viewer reloads them through the provider boundary.

## Consequences

- Concurrent viewers share downloads and immutable event memory but keep independent controls.
- Memory remains bounded by timeline count, TTL, event count, and the 22-row projection limit.
- Scrubbing is CPU work proportional to the selected event cursor. This is acceptable at the current personal-use scale and avoids snapshot storage.
- Playback is unavailable during an OpenF1 outage unless the timeline is already resident.
- Durable archives, cross-node replay, and raw telemetry analysis remain separate future decisions.

## Rejected alternatives

- Ecto or object-storage archives, because persistence is outside the product requirement.
- Periodic snapshots, because they duplicate state and create unnecessary retention semantics.
- Per-viewer provider loading, because it scales upstream work with browser count.
- GenStage or Broadway, because the bounded reducer and one shared loader do not currently exhibit measured backpressure needs.
