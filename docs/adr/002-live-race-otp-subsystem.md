# ADR-002: Live race OTP subsystem

**Date**: 2026-08-27
**Status**: Accepted

## Context

Live timing is an external, ordered, failure-prone stream shared by every connected browser. Vortex needs one coherent current race view, honest freshness states, safe reconnect behavior, and bounded memory. It does not need durable race history in the MVP.

## Decision

Run `RaceState` before `LiveFeed` under a `:rest_for_one` supervisor.

`RaceState` is the sole writer of one in-memory `RaceProjection`. For each provider `{topic, key}`, the greatest provider message identifier wins. A commit replaces current state, increments a local version, and then broadcasts that version through Phoenix PubSub. It stores no prior projections or raw telemetry series.

`LiveFeed` owns token timers, transport lifecycle, subscription health, bounded pending updates, coalescing, reconnect backoff, and REST reconciliation. Slow provider work runs under a `Task.Supervisor`.

PubSub is notification rather than storage. A LiveView subscribes before reading current state and ignores equal or older version notifications.

Reconnect does not mean live. Vortex reports stale/reconnecting/resyncing until subscriptions are healthy and REST reconciliation has completed.

The MVP is single-node. It uses GenServer state rather than Ecto, ETS, periodic snapshots, an event log, GenStage, or Broadway.

Historical playback is a separate read-only path. A bounded `ReplayStore` may cache a small number of normalized, topic-limited OpenF1 historical timelines in process memory. Each `LiveTimingLive` owns its playback cursor, timer generation, speed, and current replay projection, so one viewer cannot control another viewer or mutate the canonical live `RaceState`. Replay data expires and is reloaded after restart; it is not an event log or persistence boundary.

## Consequences

### Positive

- One upstream connection serves any number of LiveViews.
- Runtime ownership, restart behavior, and freshness are explicit.
- Memory stays bounded to current race state and pending coalesced updates.
- Duplicate, old, missed, and racing notifications are repairable.

### Negative

- A node restart intentionally loses current state and returns to cold/resyncing.
- Multi-node deployment requires a new ownership and shared-state design.
- REST reconciliation is an additional dependency during recovery.

## Alternatives considered

### Persist periodic snapshots

Rejected because no MVP feature needs race history across deployments.

### ETS current state

Deferred until measured concurrent-read contention justifies the added ownership semantics.

### GenStage or Broadway

Rejected because OpenF1 controls the input rate and Vortex replaces superseded values instead of queueing demand-controlled work.

### One feed per LiveView

Rejected because it multiplies credentials, provider quota usage, and inconsistent connection states.
