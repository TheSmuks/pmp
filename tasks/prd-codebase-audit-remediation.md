# PRD: Codebase Audit & Remediation Roadmap

## Introduction

A full audit of pmp reveals three categories of problems: (1) structural issues that violate Pike's module conventions and make the codebase fragile, (2) features documented as implemented but that are hallucinations or partial implementations, and (3) architectural gaps relative to the stated inspirations (bun, uv, cargo). This PRD provides a prioritized roadmap for fixing what's broken, removing what's fake, and building what's missing.

---

## Audit Findings

### F1. Module structure violates Pike conventions (CRITICAL)

**Problem:** The codebase scatters 17 modules across 5 subdirectories (`core/`, `transport/`, `store/`, `project/`, `commands/`) outside `Pmp.pmod/`. These are stitched together by polluting `PIKE_MODULE_PATH` with 6 directories in the shell shim. This means:

- `inherit Config;` in `module.pmod` does NOT resolve as "sub-module of Pmp" — it resolves as a top-level module named `Config` found via PIKE_MODULE_PATH search of `core/`.
- Internal modules like `Config`, `Helpers`, `Semver` are independently importable by any Pike program. `import Config; write(PMP_VERSION);` works — it shouldn't.
- With only `PIKE_MODULE_PATH=bin/` (the canonical Pike way), the entire system fails to compile. Every single inherit in `module.pmod` produces "Undefined identifier".
- The `.-prefix` inherits (`inherit .Store;`, `inherit .Install;`) work by accident — they resolve within the same directory (e.g., `store/StoreCmd.pmod` finds `store/Store.pmod`), not as sub-modules of `Pmp`.
- Every tool that touches the codebase (tests, CI, `pmp env`, `pmp run`) must replicate the 6-directory `PIKE_MODULE_PATH` hack.

**Canonical Pike pattern** (seen in `Protocols.HTTP`, `Filesystem`, `Git`):
```
Pmp.pmod/              ← package directory
  module.pmod          ← package root (import Pmp)
  Config.pmod          ← import Pmp.Config, inherit .Config
  Helpers.pmod         ← import Pmp.Helpers, inherit .Helpers
  HTTP.pmod/           ← nested sub-package
    module.pmod
  Install.pmod         ← inherit .Config, .Helpers, etc.
```

With this layout, `import Pmp` works with just `PIKE_MODULE_PATH=bin/`. No `-M` flags, no 6-directory hacks, no namespace pollution.

**Verdict:** The current structure is a veneer of organization that works only because of a brittle shim. It must be restructured into `Pmp.pmod/` following the canonical `Protocols.HTTP` pattern.

### F2. ARCHITECTURE.md claims native Filesystem.Tar — code uses system tar

**Problem:** The architecture doc states "extract via `Filesystem.Tar`" and the README claims "No external deps needed (no curl, tar, sha256sum)." But `Store.pmod:extract_targz()` shells out to `Process.run(({"tar", "xzf", ...}))`. The `need_cmd("tar")` guard was removed but the `Process.run` call remains. The `pmp doctor` command now checks for `tar` availability and the install command checks for `tar` before GitHub/GitLab installs — confirming it's a real dependency.

**Verdict:** Either switch to `Filesystem.Tar` (eliminating the external dependency) or update all documentation to accurately reflect `tar` as a required external dependency.

### F3. AGENTS.md and ARCHITECTURE.md are out of sync with actual code

**Problem:** Multiple doc/code discrepancies:
- AGENTS.md lists modules as `bin/Pmp.pmod/*.pmod` (flat), but actual files are in `bin/core/`, `bin/transport/`, etc.
- AGENTS.md says "114 shell tests" — actual count is 208
- AGENTS.md says "81 Pike unit tests" — actual count differs
- ARCHITECTURE.md data flow step 8 says "extract via Filesystem.Tar" — actually uses system `tar`
- Several function signatures documented in AGENTS.md don't match current code

**Verdict:** Documentation must be regenerated from the actual codebase after the module restructure.

### F4. No dependency version constraints (ranges)

**Problem:** `pike.json` dependencies are exact URLs with optional `#tag` pinning. There's no concept of version ranges (`^1.2.0`, `~1.2`, `>=1.0.0 <2.0.0`). Every install without `#tag` resolves to the latest semver tag. This means:
- `pmp install github.com/owner/repo` always installs the latest, even across majors
- No way to express "I want 1.x but not 2.x"
- A downstream release can break your project without you changing anything

ADR-0004 proposes range constraints but they're not implemented.

**Verdict:** Implement semver range constraints in `pike.json` following cargo/uv patterns. Minimum: caret (`^`) and tilde (`~`) ranges.

### F5. No lockfile integrity field

**Problem:** The lockfile (`pike.lock`) has no integrity checksum. A malicious or corrupted lockfile could inject arbitrary source URLs or version pins. ADR-0003 proposes a v2 lockfile format with an integrity field, but it's not implemented.

**Verdict:** Implement lockfile v2 with a self-verifying integrity checksum.

### F6. `pmp install <url>` doesn't validate the installed content matches what was requested

**Problem:** When installing a specific `#tag`, the system downloads the tarball for that tag but doesn't verify the tarball content hash matches any known value. The store computes a content hash *after* download, but there's no comparison against an expected value. This means a compromised CDN or MITM attack could serve different content for the same tag.

**Verdict:** Add optional content hash verification via lockfile. The lockfile already stores `content_sha256` — the gap is that on first install there's nothing to verify against. Consider a registry or signing mechanism for the future.

### F7. No `pmp why <module>` command

**Problem:** When a transitive dependency causes a conflict, there's no way to determine which direct dependency pulled it in. `pmp list` shows installed modules but not the dependency tree.

**Verdict:** Add `pmp why <module>` that traces the dependency path from `pike.json` direct deps to the requested module.

### F8. No workspace/monorepo support

**Problem:** ADR-0005 proposes workspace support but it's not implemented. For multi-package Pike projects, there's no equivalent to cargo's workspace or bun's workspace.

**Verdict:** Defer to post-1.0. Document as a known limitation.

### F9. `pmp env` wrapper is static shell, not Pike-native

**Problem:** The `.pike-env/bin/pike` wrapper is a generated shell script that uses `sed` to parse a config file. It doesn't inherit from the Pike module path that pmp itself uses. If the user's Pike setup changes, the wrapper may become stale.

**Verdict:** The wrapper is functional for its purpose. Not blocking, but could be improved by making it dynamically resolve paths from `pike.json` at runtime via a small Pike script instead of shell.

### F10. No `pmp publish` or registry support

**Problem:** There's no way to publish packages to a registry. All sources are git URLs. This limits discoverability and requires users to know exact URLs.

**Verdict:** Defer to post-1.0. The git-based approach is viable for the current ecosystem size. A registry requires infrastructure.

### F11. HTTP transport uses threads but doesn't clean up properly on timeout

**Problem:** In `Http.pmod:_do_get_single()`, when the HTTP thread times out, Pike can't cancel it. The code does `catch { http_thread->wait() }` but this is a best-effort leak mitigation. Pike has no thread cancellation. On repeated timeouts, threads accumulate.

**Verdict:** This is a known Pike limitation. The current mitigation is reasonable but should be documented. A future optimization could use a thread pool.

### F12. `extract_targz` uses `--no-same-permissions` which may break packages with executable scripts

**Problem:** The tar extraction uses `--no-same-permissions` which resets all permissions to the umask. This means executable scripts (like build scripts) in packages lose their execute bit.

**Verdict:** Either remove `--no-same-permissions` (and accept the security trade-off) or use `Filesystem.Tar` which gives fine-grained control.

---

## Goals

1. Restructure modules into canonical Pike layout under `Pmp.pmod/`
2. Replace system `tar` with native `Filesystem.Tar` (eliminating external deps)
3. Implement semver range constraints (`^`, `~`) in `pike.json`
4. Add lockfile v2 with integrity checksum
5. Add `pmp why <module>` for dependency tree tracing
6. Sync all documentation with actual codebase
7. Maintain 100% test pass rate through all changes

## Non-Goals

- Registry support (`pmp publish`) — post-1.0
- Workspace/monorepo support — post-1.0
- Language server or IDE integration
- GUI or TUI
- Binary package format (beyond tar.gz)
- Windows support (Pike + sh shim is POSIX-only)

---

## User Stories

### US-001: Restructure into canonical Pike module layout

**Description:** As a Pike developer, I need pmp's modules to live inside `Pmp.pmod/` following the `Protocols.HTTP` pattern so that `import Pmp` works with a single `PIKE_MODULE_PATH` entry and internal modules aren't exposed as top-level imports.

**Acceptance Criteria:**
- [ ] All 17 modules live under `bin/Pmp.pmod/` (flat or with `.pmod/` subdirectories for sub-packages)
- [ ] `module.pmod` uses `inherit .Config;` (dot-prefix) for all sub-modules
- [ ] `pike -M bin -e 'import Pmp; write(PMP_VERSION);'` works without additional `-M` flags
- [ ] `pike -M bin -e 'import Config;'` fails (Config is not a top-level module)
- [ ] Shell shim sets only `PIKE_MODULE_PATH="$_self"` (single entry)
- [ ] All internal cross-module inherits use `.Prefix` for same-directory references
- [ ] All 208 shell tests pass
- [ ] All Pike unit tests pass
- [ ] `pike bin/pmp.pike --help` produces correct output

### US-002: Replace system tar with native Filesystem.Tar

**Description:** As a user, I want pmp to work without system `tar` installed, using Pike's native `Filesystem.Tar` for extraction, so that the only runtime dependency is Pike itself.

**Acceptance Criteria:**
- [ ] `extract_targz()` uses `Filesystem.Tar` instead of `Process.run(({"tar", ...}))`
- [ ] Symlink-path-traversal validation still works after extraction
- [ ] `pmp install github.com/owner/repo` works without `tar` in PATH
- [ ] `pmp doctor` no longer warns about missing `tar`
- [ ] Install.pmod no longer checks for `tar` with `need_cmd` or `search_path`
- [ ] All 208 shell tests pass
- [ ] ARCHITECTURE.md and README.md no longer claim `tar` as a dependency (or remove the "no external deps" claim if `git` is still needed for self-hosted)

### US-003: Implement semver range constraints

**Description:** As a developer, I want to specify version ranges in `pike.json` (e.g., `"^1.2.0"`, `"~1.2"`) so that I get compatible updates without pulling breaking changes.

**Acceptance Criteria:**
- [ ] `pike.json` supports range prefixes in source URLs: `github.com/owner/repo#^1.2.0`
- [ ] Caret (`^`) range: `^1.2.3` allows `>=1.2.3, <2.0.0`; `^0.2.3` allows `>=0.2.3, <0.3.0`
- [ ] Tilde (`~`) range: `~1.2.3` allows `>=1.2.3, <1.3.0`
- [ ] Exact pin (`#v1.2.3`) behavior unchanged
- [ ] No `#tag` (latest) behavior unchanged
- [ ] `source_to_version()` returns range string for range-prefixed versions
- [ ] `install_one()` resolves latest tag within range constraint
- [ ] New function `satisfies_range(string tag, string range)` in Semver.pmod
- [ ] Lockfile stores exact resolved version (not the range)
- [ ] All existing tests pass; new tests for range resolution
- [ ] Typecheck/lint passes

### US-004: Add lockfile v2 with integrity checksum

**Description:** As a CI engineer, I want the lockfile to include a self-verifying integrity checksum so that tampered or corrupted lockfiles are detected before install.

**Acceptance Criteria:**
- [ ] Lockfile v2 header: `# pmp lockfile v2`
- [ ] New line after entries: `# integrity\t<sha256-of-all-entry-lines>`
- [ ] `read_lockfile()` validates integrity checksum; dies on mismatch
- [ ] `write_lockfile()` computes and writes integrity line
- [ ] v1 lockfiles are still readable (forward compat)
- [ ] v2 lockfiles rejected by old pmp with "update pmp" message
- [ ] All existing tests pass; new tests for integrity verification
- [ ] Typecheck/lint passes

### US-005: Add `pmp why <module>` dependency tree tracing

**Description:** As a developer, I want to trace why a transitive dependency was installed so that I can resolve version conflicts.

**Acceptance Criteria:**
- [ ] `pmp why <module>` prints the dependency chain from `pike.json` direct dep to the requested module
- [ ] Output format: `module v1.2.3 (direct)` or `module v1.2.3 ← parent v2.0.0 ← root v1.0.0`
- [ ] Reports "module not found" if the module isn't installed
- [ ] Reads dependency tree from lockfile + pike.json of each package
- [ ] Typecheck/lint passes

### US-006: Sync all documentation with actual codebase

**Description:** As a contributor, I need documentation to accurately reflect the current codebase so that I can understand and modify the system correctly.

**Acceptance Criteria:**
- [ ] AGENTS.md lists correct module paths (after restructure)
- [ ] AGENTS.md lists correct test counts
- [ ] ARCHITECTURE.md data flow reflects actual implementation (Filesystem.Tar, not system tar)
- [ ] README.md accurately describes external dependencies
- [ ] All doc references to `bin/Pmp.pmod/*.pmod` updated to `bin/Pmp.pmod/`
- [ ] Function signatures in docs match actual code

---

## Functional Requirements

- FR-1: All modules must reside under `bin/Pmp.pmod/` and use `.-prefix` inherits for sub-modules
- FR-2: `PIKE_MODULE_PATH` must require only the `bin/` directory for `import Pmp` to work
- FR-3: Tar extraction must use Pike's `Filesystem.Tar`, not system `tar`
- FR-4: `source_to_version()` must recognize range prefixes (`^`, `~`) and return them as range strings
- FR-5: `satisfies_range(tag, range)` must determine whether a tag satisfies a range constraint
- FR-6: `install_one()` must filter resolved tags through `satisfies_range()` when a range is specified
- FR-7: Lockfile v2 must include an integrity line computed over all entry lines
- FR-8: `read_lockfile()` must verify integrity on v2 lockfiles and die on mismatch
- FR-9: `cmd_why()` must BFS-walk the dependency tree from direct deps to the target module
- FR-10: All documentation files must be regenerated from actual code after structural changes

## Non-Goals

- Package registry or `pmp publish`
- Workspace/monorepo support
- Binary package format
- Windows support
- IDE/LSP integration
- Plugin system

## Design Considerations

### Module layout target

```
bin/Pmp.pmod/
  module.pmod           ← inherit .Config, .Helpers, .Semver, .Source, ...
  Config.pmod
  Helpers.pmod
  Semver.pmod
  Source.pmod
  Http.pmod
  Resolve.pmod
  Store.pmod
  StoreCmd.pmod
  Lockfile.pmod
  Manifest.pmod
  Validate.pmod
  Verify.pmod
  Project.pmod
  Env.pmod
  Install.pmod
  Update.pmod
  LockOps.pmod
```

All flat under `Pmp.pmod/`. If logical grouping is desired later, use Pike's `HTTP.pmod/module.pmod` nested pattern — but flat is simpler and matches the current cross-module inherit graph (commands inherit from all layers).

### Range constraint syntax

Follows cargo conventions:
- `^1.2.3` — compatible with 1.2.3 (allows >=1.2.3, <2.0.0)
- `^0.2.3` — compatible with 0.2.3 (allows >=0.2.3, <0.3.0)
- `~1.2.3` — patch-level changes only (allows >=1.2.3, <1.3.0)
- `~1.2` — minor-level changes (allows >=1.2.0, <1.3.0)

Encoded in `pike.json` as: `"github.com/owner/repo#^1.2.0"`

### Lockfile v2 format

```
# pmp lockfile v2 — DO NOT EDIT
# name<TAB>source<TAB>tag<TAB>commit_sha<TAB>content_sha256
Foo  github.com/owner/repo  v1.2.3  abc123  def456
Bar  github.com/other/repo  v2.0.0  789abc  012def
# integrity<TAB><sha256-of-above-entry-lines>
```

## Technical Considerations

- The module restructure (US-001) is the highest priority because it unblocks idiomatic Pike usage and must be done before other changes to avoid merge conflicts.
- `Filesystem.Tar` may not handle all tar formats that system `tar` does. Need to verify it handles `.tar.gz` from GitHub/GitLab archive endpoints.
- Semver range constraints require careful spec compliance. Test against cargo's resolver behavior for edge cases.
- Lockfile v2 migration: pmp should auto-detect v1 vs v2 and handle both. No migration command needed.
- The module restructure is a rename-only operation — no logic changes. This minimizes risk and makes review straightforward.

## Success Metrics

- `import Pmp` works with a single `PIKE_MODULE_PATH` entry
- Zero external dependencies for GitHub/GitLab installs (only Pike required)
- `pmp install github.com/owner/repo#^1.0.0` installs the latest 1.x version
- `pike.lock` self-verifies integrity on every read
- `pmp why <module>` traces the full dependency path
- All documentation accurately reflects the codebase
- 100% test pass rate (208 shell + Pike unit tests)

## Open Questions

- Should `Filesystem.Tar` handle gzip decompression, or do we need `Gz.File` to decompress first?
- Should the lockfile integrity line cover the header comment, or just entry lines?
- Should `pmp why` support `--tree` for full tree output, or just the path to a specific module?
- Is flat layout under `Pmp.pmod/` acceptable, or do we want nested sub-packages (e.g., `Pmp.pmod/Transport.pmod/`)?

## Implementation Order

1. **US-001: Module restructure** — foundation for everything else
2. **US-002: Native tar extraction** — eliminates external dependency
3. **US-006: Documentation sync** — reflects the new structure
4. **US-003: Semver ranges** — new feature
5. **US-004: Lockfile v2** — requires stable format first
6. **US-005: `pmp why`** — requires stable dependency tree format
