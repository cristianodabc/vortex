# ADR-004: Reference-data cache

**Date**: 2026-08-27
**Status**: Accepted

## Context

Schedules, results, and standings change at different rates. Provider quotas apply to the application, not to each browser, and provider outages should not erase usable last-known data.

## Decision

Use a supervised in-memory cache behind `Vortex.F1.Cache`. The server owns normalized resources and coalesces concurrent loads by resource key. Loader functions execute under `Vortex.F1.TaskSupervisor`; the cache process never performs HTTP itself.

A fresh hit returns immediately. A stale hit returns last-known data with freshness metadata and starts one background revalidation. A cold miss waits for the shared in-flight task. Failed refreshes preserve stale data when available.

TTL and stale policy are resource-specific. Completed historical results are effectively immutable for the process lifetime; current schedules and standings revalidate more frequently. Provider `Retry-After` values suppress early refresh attempts. An explicit entry cap evicts the oldest resources.

Cache state is node-local and intentionally disposable. Restarting Vortex refetches data.

## Consequences

### Positive

- Browser count does not multiply provider calls.
- Panels can retain last-known data during provider failure.
- Loader coalescing avoids refresh stampedes.
- No database or external cache is required.

### Negative

- Cold application restart temporarily loses cached data.
- Multi-node instances would have independent caches.
- The cache process needs explicit clock and task injection for deterministic tests.

## Alternatives considered

### Cache in each LiveView

Rejected because it duplicates requests and creates inconsistent freshness across users.

### Cachex

Deferred because the initial cache needs a small policy-specific API and does not justify another dependency.

### ETS

Deferred until measured contention shows GenServer reads are a bottleneck.

### Database persistence

Rejected because the MVP has no user-facing persistence requirement.
