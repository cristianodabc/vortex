# ADR-001: F1 provider boundary

**Date**: 2026-08-27
**Status**: Accepted

## Context

Vortex needs schedules, completed results, championship standings, and current-session timing. No single unofficial provider offers the required coverage, history, live access, and access terms. Provider schemas and availability can change independently of Vortex.

## Decision

`Vortex.F1` is the only Formula racing domain API used by web modules. It returns Vortex-owned structs and presentation-safe errors.

Jolpica is the reference provider for schedules, completed results, driver standings, and constructor standings. OpenF1 is the timing provider for historical sessions and, when personal live credentials are configured, current sessions.

Provider capabilities are expressed through narrow behaviours. Req clients, response normalization, pagination, retries, rate limits, and authentication remain inside adapters. Provider maps, Req responses, raw bodies, credentials, and tokens never cross the context boundary.

All provider values are untrusted. Adapters validate identifiers, bounded display strings, enum-like values, nullable fields, and team colors without dynamically creating atoms.

## Consequences

### Positive

- LiveViews remain independent of provider schemas and HTTP/MQTT libraries.
- Tests can inject deterministic provider fakes without network access.
- Provider changes are isolated to adapters and fixture contracts.
- Secret handling and error redaction have one enforceable boundary.

### Negative

- Normalized models require deliberate mapping and maintenance.
- Some provider-specific detail will be unavailable until Vortex adds it intentionally.
- Cross-provider identifiers may require explicit reconciliation.

## Alternatives considered

### Call providers directly from LiveViews

Rejected because browser count would multiply provider requests, credentials and error handling would leak into web processes, and schemas would couple directly to templates.

### Use only OpenF1

Rejected because its historical coverage starts in 2023 and the reference-data contract is less suitable for Vortex's schedule/results requirements.

### Use FastF1 through a Python sidecar

Rejected because it adds another runtime and failure boundary without improving the MVP's live transport.
