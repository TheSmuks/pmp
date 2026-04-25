# Production Readiness Audit: Consolidated Adversarial Report

**Date**: 2026-04-23
**Method**: 6 independent adversarial agents, complete isolation, no coordination
**Scope**: Entire pmp codebase (14 modules + entry point + tests + installer)

---

## Executive Summary

6 independent adversarial agents audited the codebase simultaneously with no knowledge of each other. Each agent's sole mandate was to prove failure. The results converge on a consistent set of structural weaknesses.

| Metric | Count |
|---|---|
| **CRITICAL** (crashes, data loss, security) | 18 |
| **HIGH** (wrong behavior, spec violations) | 35 |
| **MEDIUM** (edge cases, fragile code) | 40 |
| **LOW** (style, documentation) | 18 |
| **Total findings** | **111** |
| **ACID violations** | **34** |
| **Security vulnerabilities** | **8** |

**Verdict**: NOT production-ready. The codebase handles happy paths well but fails systematically under adversarial conditions. The most severe category is ACID violations in stateful orchestrators (Install, Project, Lockfile) — partial failures leave the system in inconsistent states with no rollback.

---

## CRITICAL Findings

### C-01: run_cleanup() never called on normal exit
**Agent**: 1 (Core Runtime) | **File**: `bin/pmp.pike` | **Severity**: CRITICAL

`run_cleanup()` is defined but never registered via `atexit()` or called on normal/die exit paths. Any cleanup logic it contains is dead code. Temp files, locks, and partial state are never cleaned up on normal termination.

### C-02: atomic_write fallback is non-atomic
**Agent**: 1, 3, 6 | **Files**: `Helpers.pmod`, `Store.pmod`, `Lockfile.pmod` | **Severity**: CRITICAL

When `Stdio.File()->open(tmp, "wct")` fails (permissions, disk full), the fallback does `Stdio.write_file(path, content)` — a plain write with no rename. Crash during this write corrupts the file. The atomicity guarantee is conditional on an implementation detail.

### C-03: Cache.pmod is dead code — inherited but unused
**Agent**: 1 | **File**: `module.pmod` | **Severity**: CRITICAL

`Cache.pmod` exists and is inherited in `module.pmod` but is never used anywhere. Dead code in the module export path increases attack surface and confuses contributors.

### C-04: Truncated HTTP responses accepted as complete
**Agent**: 2 (Source/HTTP) | **File**: `Http.pmod` | **Severity**: CRITICAL

No Content-Length validation after body download. If the connection drops mid-transfer, the partial body is returned as if complete. Combined with SHA verification, this could be caught — but only if the server provides a content hash.

### C-05: Credential leakage in error messages
**Agent**: 2 | **File**: `Source.pmod` | **Severity**: CRITICAL

Source URLs containing `user:password@host` are included verbatim in `die()` and `warn()` messages. Credentials appear in stderr and any log collection system.

### C-06: SSRF via crafted source URLs
**Agent**: 2 | **File**: `Source.pmod` | **Severity**: CRITICAL

No private IP blocklist. Source URLs pointing to `127.0.0.1`, `169.254.169.254` (AWS metadata), `10.x.x.x`, or `192.168.x.x` are accepted and fetched. An attacker-controlled pike.json could trigger requests to internal services.

### C-07: file:// URLs misclassified as selfhosted
**Agent**: 2 | **File**: `Source.pmod` | **Severity**: CRITICAL

`file://` URLs are classified as `selfhosted` and processed through HTTP fetch logic. They should be rejected or handled via local filesystem operations. Processing them as HTTP URLs could expose local files.

### C-08: Symlink extraction TOCTOU allows arbitrary file write
**Agent**: 3 (Store/Lockfile) | **File**: `Store.pmod` | **Severity**: CRITICAL

During tar extraction, symlinks are checked then acted upon with a time gap. An attacker-crafted tarball with a symlink pointing to a sensitive file could exploit this race to write outside the store directory.

### C-09: No download integrity verification
**Agent**: 3 | **File**: `Store.pmod` | **Severity**: CRITICAL

Download completes, hash is computed, but if the hash doesn't match, the store entry may already be partially written. The integrity check happens after extraction, not before commit.

### C-10: SHA truncation collision window
**Agent**: 3 | **File**: `Store.pmod` | **Severity**: CRITICAL

Store entry names use only 8 hex chars of SHA-256. For a shared store with many packages, the collision probability is non-trivial (~6.7% at 100K entries). Collisions cause silent overwrites.

### C-11–C-16: Six semver spec violations
**Agent**: 4 (Semver) | **File**: `Semver.pmod` | **Severity**: CRITICAL

| ID | Violation | Semver Spec § |
|---|---|---|
| S-01 | Leading zeros accepted (`"01.2.3"` parses) | §2 |
| S-02 | Empty prerelease accepted (`"1.2.3-"` parses) | §9 |
| S-03 | One/two-part versions accepted (`"1"` → 1.0.0) | §2 |
| S-04 | Prerelease identifiers unvalidated (`"1.0.0-alpha/beta"`) | §9 |
| S-05 | Build metadata identifiers unvalidated | §10 |
| S-06 | Prerelease numeric leading zeros accepted (`"1.0.0-01"`) | §9 |

All six violate the semver specification. `parse_semver` returns success for inputs that are not valid semver.

### C-17: cmd_update → cmd_install_all deadlock on project_lock
**Agent**: 5 (Install/Env) | **File**: `Install.pmod` | **Severity**: CRITICAL

`cmd_update` acquires a project lock, then calls `cmd_install_all` which attempts to acquire the same lock. If the lock is non-reentrant, this deadlocks. If reentrant, the lock provides no actual isolation.

### C-18: install.sh uses bash-specific pipefail with #!/bin/sh
**Agent**: 6 (Tests/CLI) | **File**: `install.sh` | **Severity**: CRITICAL

The shebang is `#!/bin/sh` but the script uses `set -o pipefail`, which is bash-only. On systems where `/bin/sh` is dash (Debian, Ubuntu), the installer crashes immediately.

---

## HIGH Findings (35)

### Agent 1 — Core Runtime (8)

| ID | Finding | File |
|---|---|---|
| H-01 | json_field silently returns wrong type for non-string JSON values | Helpers.pmod |
| H-02 | find_project_root returns empty string for empty input | Helpers.pmod |
| H-03 | No SIGPIPE handler — process killed when piping to head | pmp.pike |
| H-04 | compute_sha256 doesn't verify the file still exists mid-stream | Helpers.pmod |
| H-05 | die() doesn't call run_cleanup — temp files leak on error | Helpers.pmod |
| H-06 | info/warn/debug don't check verbosity level before formatting | Helpers.pmod |
| H-07 | Arg.parse doesn't validate unknown commands — silent no-op | pmp.pike |
| H-08 | module.pmod inherit order determines symbol precedence — fragile | module.pmod |

### Agent 2 — Source/HTTP/Resolve (7)

| ID | Finding | File |
|---|---|---|
| H-09 | Silent partial pagination — stale 'latest' tags | Resolve.pmod |
| H-10 | Thread leaks on HTTP timeout | Http.pmod |
| H-11 | Empty SHA values in lockfile entries when resolution fails | Resolve.pmod |
| H-12 | Incomplete GitLab URL encoding | Source.pmod |
| H-13 | Hardcoded HTTPS for selfhosted git — no HTTP option | Source.pmod |
| H-14 | Weak redirect cycle detection (count-based, not URL-based) | Http.pmod |
| H-15 | Retry-After header not respected on 429 responses | Http.pmod |

### Agent 3 — Store/Lockfile (5)

| ID | Finding | File |
|---|---|---|
| H-16 | Non-atomic store install leaving orphans on failure | Store.pmod |
| H-17 | Lock stale-detection race on NFS | Store.pmod |
| H-18 | No disk space check before extraction | Store.pmod |
| H-19 | Lockfile backup (.prev) non-atomic | Lockfile.pmod |
| H-20 | No lockfile entry field validation | Lockfile.pmod |

### Agent 4 — Semver/Manifest/Project (7)

| ID | Finding | File |
|---|---|---|
| H-21 | add_to_manifest has no success/failure signal (returns void) | Manifest.pmod |
| H-22 | add_to_manifest accepts unvalidated name and source | Manifest.pmod |
| H-23 | cmd_remove non-atomic 3-step modification (ACID) | Project.pmod |
| H-24 | cmd_remove lockfile rewritten unconditionally | Project.pmod |
| H-25 | cmd_clean count incremented before removal attempted | Project.pmod |
| H-26 | cmd_clean no store orphan cleanup | Project.pmod |
| H-27 | parse_deps silent return on malformed dependencies | Manifest.pmod |

### Agent 5 — Install/Env (8)

| ID | Finding | File |
|---|---|---|
| H-28 | Modules installed but lockfile write fails → inconsistent state | Install.pmod |
| H-29 | cmd_rollback has no lock — concurrent rollback race | Install.pmod |
| H-30 | Single-module update removes old symlink before new ready | Install.pmod |
| H-31 | Store prune deletes entries referenced by broken symlinks | StoreCmd.pmod |
| H-32 | cmd_run: potential command injection via unsanitized args | Env.pmod |
| H-33 | cmd_install_all ctx["visited"] not reset on retry | Install.pmod |
| H-34 | cmd_changelog: no common ancestor handling | Install.pmod |
| H-35 | print_update_summary displays wrong comparison for downgrade | Install.pmod |

---

## ACID Violations (34 total, cross-referenced)

### Atomicity (12)

| # | Module | Scenario | Result |
|---|---|---|---|
| A-01 | Install | 4/5 deps installed, 5th fails | Project in broken state, no rollback |
| A-02 | Install | Download succeeds, symlink fails | Orphan in store |
| A-03 | Project | cmd_remove: pike.json updated, symlink removal fails | Manifest inconsistent with filesystem |
| A-04 | Project | cmd_remove: steps 1-2 ok, lockfile write dies | Process exits, lockfile corrupt |
| A-05 | Install | cmd_update: old symlink removed, new download fails | Module missing entirely |
| A-06 | Lockfile | write_lockfile: temp written, rename fails | .prev exists, lockfile unchanged, temp orphan |
| A-07 | Store | store_install: download ok, extraction fails | Partial store entry |
| A-08 | Project | cmd_init: pike.json exists check then write (TOCTOU) | Data loss if race |
| A-09 | Lockfile | lockfile backup (.prev) written non-atomically | Crash leaves partial .prev |
| A-10 | Install | cmd_rollback: 3/5 modules restored, 4th fails | Mixed old/new state |
| A-11 | Manifest | add_to_manifest: JSON parse ok, write fails | pike.json may be truncated |
| A-12 | Project | cmd_clean: count in pass 1, remove in pass 2 | Wrong count on failure |

### Consistency (8)

| # | Module | Invariant Violated |
|---|---|---|
| C-01 | Install | lock_entries doesn't match installed modules |
| C-02 | Project | pike.json doesn't match ./modules/ symlinks |
| C-03 | Store | Store entry .pmp-meta doesn't match content hash |
| C-04 | Lockfile | pike.lock doesn't match pike.lock.prev after failed update |
| C-05 | Semver | parse_semver accepts invalid semver → wrong version resolution |
| C-06 | Resolve | latest_tag returns stale tag due to pagination truncation |
| C-07 | Project | cmd_clean reports N cleaned but M remain |
| C-08 | Install | ctx["visited"] leaks between install_one calls |

### Isolation (6)

| # | Module | Race Condition |
|---|---|---|
| I-01 | Store | Two installs race for same store entry |
| I-02 | Lockfile | Two processes write lockfile simultaneously |
| I-03 | Project | Two removes modify same pike.json concurrently |
| I-04 | Install | cmd_update and cmd_install_all deadlock on project_lock |
| I-05 | Store | O_EXCL lock stale after crash, blocks subsequent installs |
| I-06 | Store | cmd_store prune races with concurrent install |

### Durability (8)

| # | Module | Issue |
|---|---|---|
| D-01 | Helpers | atomic_write fallback is non-atomic |
| D-02 | Store | SHA-256 truncated to 8 chars — collision risk |
| D-03 | Lockfile | .prev backup may be corrupted |
| D-04 | Install | Successful installs lost if lockfile write fails and user re-runs |
| D-05 | Store | Store entry overwritten on collision (no detection) |
| D-06 | Http | Truncated response treated as complete |
| D-07 | Resolve | Resolved commit SHA empty on error — written to lockfile |
| D-08 | Store | Tar symlink attack writes outside store |

---

## Security Vulnerabilities (8)

| # | Finding | Severity | File |
|---|---|---|---|
| SEC-01 | Credential leakage in error messages (user:pass@host) | CRITICAL | Source.pmod |
| SEC-02 | SSRF via crafted source URLs (no private IP blocklist) | CRITICAL | Source.pmod |
| SEC-03 | Symlink extraction TOCTOU (path traversal in tar) | CRITICAL | Store.pmod |
| SEC-04 | file:// URLs processed as HTTP | HIGH | Source.pmod |
| SEC-05 | Command injection in cmd_run | HIGH | Env.pmod |
| SEC-06 | Predictable temp file names | MEDIUM | Helpers.pmod |
| SEC-07 | No signature/ checksum in installer (curl pipe sh) | HIGH | install.sh |
| SEC-08 | No lockfile entry field validation (malicious content) | MEDIUM | Lockfile.pmod |

---

## Test Coverage Gaps (11)

| # | Missing Test Coverage | Impact |
|---|---|---|
| T-01 | Remote install (no network tests) | Core functionality untested in CI |
| T-02 | Rollback (pike.lock.prev restore) | Critical recovery path untested |
| T-03 | Concurrent operations | Race conditions undetected |
| T-04 | Error paths in install_one | Partial failure handling unverified |
| T-05 | cmd_update with version conflicts | Conflict resolution untested |
| T-06 | Large dependency graphs (100+) | Performance regression undetected |
| T-07 | Malformed tar archives | Security: path traversal untested |
| T-08 | Malformed lockfile (corrupt, BOM, CRLF) | Recovery from corruption untested |
| T-09 | Disk full scenarios | Graceful degradation untested |
| T-10 | Signal handling (SIGINT during install) | Cleanup on interrupt untested |
| T-11 | Store prune while install running | Isolation untested |

---

## Standardization Issues (4 cross-cutting)

| # | Issue | Details |
|---|---|---|
| X-01 | BEHAVIOR_SPEC.md contradicts actual code | Spec says `parse_semver("01.2.3") == 0`; code returns valid mapping |
| X-02 | Inconsistent error handling | Semver returns 0, Manifest returns void, Project calls die() — no consistent contract |
| X-03 | No centralized dependency name validation | Fragmented across 4 modules; `add_to_manifest` has none |
| X-04 | DRY violation in store_install_* (3 near-identical functions) | Store.pmod has store_install_github, store_install_gitlab, store_install_selfhosted — 80% code duplication |

---

## Priority-Ranked Fix Plan

### Phase 1 — Block release (CRITICAL, 18 items)

| # | Finding | Fix | Acceptance |
|---|---|---|---|
| 1 | C-18: install.sh POSIX | Remove pipefail or change shebang to bash | Installer runs on dash |
| 2 | C-17: update deadlock | Make project_lock reentrant or separate lock paths | cmd_update completes without deadlock |
| 3 | C-01: run_cleanup dead code | Wire into atexit or explicit cleanup in die() | Temp files cleaned on all exit paths |
| 4 | C-02: atomic_write fallback | Remove fallback; die on O_EXCL failure | No silent non-atomic writes |
| 5 | C-04: HTTP truncation | Validate Content-Length after download | Truncated responses rejected |
| 6 | C-05: Credential leakage | Strip credentials before logging | No passwords in stderr |
| 7 | C-06: SSRF | Add private IP blocklist | Internal IPs rejected |
| 8 | C-07: file:// handling | Reject or handle locally | No HTTP fetch of file:// URLs |
| 9 | C-08: Symlink extraction | Extract to temp, validate, then move | No write outside store |
| 10 | C-09: Download integrity | Verify hash before committing to store | Mismatch → no store entry |
| 11 | C-10: SHA collision | Increase to 16 chars | Collision at 100K entries < 0.001% |
| 12-17 | S-01 to S-06: Semver | Fix parse_semver validation | All semver spec cases pass |
| 18 | C-03: Dead Cache.pmod | Remove or implement | No dead code in module.pmod |

### Phase 2 — Block production use (HIGH, 35 items)

Focus areas:
- **Install atomicity**: Install-all must track completed steps and rollback on failure
- **cmd_remove atomicity**: Reverse-order execution with rollback
- **cmd_clean correctness**: Single-pass remove with count
- **Lockfile durability**: Validate before write, backup atomically
- **HTTP robustness**: Proper retry, pagination, timeout handling
- **Manifest validation**: Return codes, name validation, error signaling

### Phase 3 — Production hardening (MEDIUM, 40 items)

- Edge cases in semver, source parsing, lockfile reading
- Error message quality (actionable, no information leakage)
- Disk space checks, signal handling, SIGPIPE protection
- BEHAVIOR_SPEC.md alignment with code

### Phase 4 — Excellence (LOW, 18 items)

- Dead code removal
- DRY refactoring (store_install_*)
- Documentation accuracy
- Code style consistency

---

## Agent Convergence Analysis

Areas where multiple independent agents found the SAME issue (high confidence):

| Issue | Agents that found it |
|---|---|
| atomic_write fallback non-atomic | 1, 3, 6 |
| ACID violations in install orchestrators | 1, 5, 6 |
| cmd_remove non-atomicity | 4, 5, 6 |
| Lockfile backup non-atomic | 3, 4, 5 |
| No disk space checking | 3, 5 |
| Silent error swallowing | 2, 4, 5 |
| DRY violation in store_install_* | 3, 5, 6 |
| Test isolation failures | 1, 6 |

These convergent findings represent the highest-priority fixes — they are not subjective; they were independently discovered by agents with no coordination.

---

## Methodology Notes

- 6 agents ran in complete isolation — no shared state, no communication
- Each agent had the full adversarial mandate: assume broken, prove failure
- Agents could not see each other's findings during execution
- Convergence was emergent, not coordinated
- Only the consolidated report was written after all agents completed
- Agent 4's detailed per-finding report is preserved in AUDIT_FINDINGS.md

---

*Report generated by 6 independent adversarial agents. No agent knew about the others or that a consensus was being built.*
