# 0002: Remove Cache.pmod (Orphaned Module)

**Status**: Accepted
**Date**: 2026-04-30
**Decision Maker**: @TheSmuks

## Context

Cache.pmod was implemented (~140 lines) with full ETag/Last-Modified support and 18 adversarial tests (CacheAdversarialTests.pike). Despite being feature-complete, it was never inherited into module.pmod or called by any other module — Http.pmod, Install.pmod, and all other modules made no reference to cache_get, cache_put, cache_clear, cache_prune, or any other Cache.pmod symbol.

The module was dead code adding maintenance burden without providing any runtime value.

## Decision

Remove Cache.pmod and CacheAdversarialTests.pike entirely. No behavior change occurs since no code path ever reached Cache.pmod.

If HTTP caching is needed in the future, it should be designed with explicit integration into Http.pmod from the start — not built as a standalone module hoping to be wired in later.

## Consequences

### Positive

- ~140 lines of dead code removed
- 18 test methods removed (tests for a module that was never used)
- One less module to maintain and keep in sync with API changes
- No orphaned symbols in the codebase

### Negative

- If caching is needed later, it must be reimplemented. The removed implementation was never validated in production, so reimplementing with proper integration is preferable to resurrecting orphaned code.

### Neutral

- No change in pmp behavior — no code path ever reached Cache.pmod.

## Alternatives Considered

### Wire Cache.pmod into Http.pmod

Could have connected the cache to http_get/http_get_safe. Rejected because the cache was designed in isolation without considering Http.pmod's retry logic, redirect handling, and timeout behavior. A properly integrated cache should be designed with those constraints from the start.

### Keep as dead code for future use

Rejected because dead code is a maintenance liability. Every module rename, API change, or test refactor would need to consider a module that provides no value.
