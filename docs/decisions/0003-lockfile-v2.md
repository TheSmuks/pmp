# 0003: Lockfile v2 — Per-Entry Integrity and Whole-File Checksum

**Status**: Accepted
**Date**: 2026-04-30
**Decision Maker**: @TheSmuks

## Context

The current lockfile (v1) is a tab-separated, line-oriented format with 5 fields per entry: `name`, `source`, `tag`, `commit_sha`, `content_sha256`. It includes a version header (`# pmp lockfile v1`) and a column-header comment line, but has two structural gaps:

1. **No per-entry integrity binding to the store.** Each entry records `content_sha256`, but this is the hash written into `.pmp-meta` at install time — it is not verified against the store directory contents on read. `Verify.pmod` recomputes `compute_dir_hash` and compares, but the lockfile itself carries no field for this. A tampered store entry would go undetected until an explicit `pmp verify`.

2. **No whole-file checksum.** The lockfile has no top-level integrity check. Any line-level corruption (truncated write, editor save, merge conflict residue) is detected only if it happens to break field count or produce an invalid name. Subtle corruption — a changed SHA, a swapped tag — passes silently.

3. **Filename is `pike.lock`.** The name predates the `pmp` rename and is inconsistent with the rest of the tooling.

The lockfile is a trust anchor: `pmp install` uses it to decide what is already installed and what needs downloading. A corrupt lockfile produces wrong installs with no warning.

## Decision

Introduce a v2 lockfile format with three additions over v1:

1. **Per-entry `integrity` field** (6th column): `sha256-<hex>` representing the `compute_dir_hash` output for the store entry directory. This binds each lockfile line to the exact directory contents in the store, making tampering detectable on read without requiring `pmp verify`.

2. **Mandatory version header and whole-file checksum.** The first line is `# pmp lockfile v2`. The last line is `# checksum: <sha256-hex>` covering all preceding lines (including headers and data lines). This detects truncation, line-level corruption, and merge conflicts.

3. **Rename `pike.lock` to `pmp.lock`.** A symlink `pike.lock -> pmp.lock` is maintained for two release versions to allow gradual migration.

Backward compatibility: `read_lockfile` detects v1 vs v2 by the header line. V1 lockfiles are read successfully and written back as v2 on the next `write_lockfile` call. No data is lost — v1 entries get an empty `integrity` field, filled on the next install.

## Format Specification

```
# pmp lockfile v2
# name\tsource\ttag\tcommit_sha\tcontent_sha256\tintegrity
Public.pmod	https://github.com/example/Public.git	v1.2.0	a1b2c3d4...	e5f6a7b8...	sha256-abc123def456...
Auth.pmod	https://github.com/example/Auth.git	v3.0.0	f9e8d7c6...	b5a4c3d2...	sha256-789abc012def...
# checksum: <sha256-of-all-lines-above>
```

Rules:

- Lines starting with `#` are comments, except the version header and checksum line.
- The first line **must** be exactly `# pmp lockfile v2`.
- The second line is a column-header comment for human readability.
- Data lines are tab-separated with exactly 6 fields.
- The `integrity` field uses the format `sha256-<hex>` (matching the output of `compute_dir_hash` in Store.pmod). An empty string means the integrity is not yet computed (migrated from v1).
- The last line **must** be `# checksum: <sha256-hex>`. The checksum input is the concatenation of all lines above it, joined by `\n`, including trailing newline. Implementation: `Crypto.SHA256.hash(body + "\n")` where `body` is everything before the checksum line.
- Trailing blank lines after the checksum are ignored on read.

## Migration Strategy

### Reading

1. `read_lockfile` opens the file and inspects the first non-empty line.
2. If it matches `# pmp lockfile v2`, parse as v2: verify the checksum, then parse 6-field data lines. Empty `integrity` fields are accepted.
3. If it matches `# pmp lockfile v1`, parse as v1 (current 5-field logic). Return entries with a 6th field set to `""`.
4. If no version header is found, fail as before ("lockfile has no version header").

### Writing

1. `write_lockfile` always writes v2 format.
2. When the target file is `pike.lock` and no `pmp.lock` exists, write to `pmp.lock` and create `pike.lock` as a symlink to `pmp.lock`.
3. When `pmp.lock` exists, write to it normally. If `pike.lock` is a symlink to `pmp.lock`, leave it. If `pike.lock` is a standalone file (pre-migration), remove it after writing `pmp.lock`.

### Filename Transition

| Release | Behavior |
|---------|----------|
| Current | Reads and writes `pike.lock` |
| Next 2 releases | Writes `pmp.lock`, creates `pike.lock -> pmp.lock` symlink on first write. Reads both `pmp.lock` (preferred) and `pike.lock` (fallback). |
| After transition | Reads and writes `pmp.lock` only. `pike.lock` symlink ignored if present. |

### No Data Loss

- V1 entries (5 fields) are padded to 6 fields with empty `integrity`.
- The next `pmp install` that touches each entry recomputes `compute_dir_hash` and fills the `integrity` field.
- All existing fields (`name`, `source`, `tag`, `commit_sha`, `content_sha256`) are preserved exactly.

## Consequences

### Positive

- **Tamper detection on every read.** Corrupted store entries or lockfile lines are caught at `read_lockfile` time, not only during `pmp verify`.
- **Whole-file integrity.** Truncated writes, merge conflicts, and line-level corruption are detected immediately via the checksum.
- **Consistent naming.** `pmp.lock` aligns with the tool name. The transition period prevents breakage.
- **Deterministic format.** Entries sorted by name (already the case via `merge_lock_entries`), checksum computed over the canonical body. Lockfile diffs are meaningful.

### Negative

- **Larger lockfiles.** The `integrity` field adds ~74 bytes per entry (`sha256-` prefix + 64 hex chars). Negligible for typical project sizes (< 50 dependencies).
- **Checksum coupling.** Any tool that edits the lockfile must recompute the checksum. This is intentional — it prevents silent modification.
- **Migration code path.** `read_lockfile` must handle both v1 and v2 for the transition period. This is bounded: v1 support can be removed after the transition releases.

### Neutral

- `pike.lock` users see a new `pmp.lock` file and a symlink. Git will track the rename naturally if `pike.lock` is committed.
- The `integrity` field is empty for migrated v1 entries until the next install. This is expected and does not affect correctness.

## Implementation Steps

Changes are confined to `bin/project/Lockfile.pmod`, with minor updates in `bin/Pmp.pmod/Project.pmod` for filename resolution.

1. **Update `LOCKFILE_VERSION` constant** from `1` to `2`.

2. **Add `compute_checksum` helper** — takes a string (the lockfile body) and returns `sha256-<hex>`. Uses `Crypto.SHA256.hash()`.

3. **Update `lockfile_add_entry`** — accept an optional 6th `integrity` parameter (default `""`). Return entries with 6 fields instead of 5.

4. **Update `write_lockfile`** —
   - Validate entries have 6 fields (update the `sizeof(entry) < 5` check to `< 6`).
   - Write v2 header: `# pmp lockfile v2`.
   - Write column header with 6 fields.
   - Write data lines with 6 tab-separated fields.
   - Compute checksum over all written lines.
   - Append `# checksum: <hex>` as the last line.
   - Handle `pmp.lock` / `pike.lock` filename logic (write to `pmp.lock`, create symlink).

5. **Update `read_lockfile`** —
   - Detect v1 vs v2 from the version header.
   - For v2: extract and verify the checksum line before parsing data. Strip the checksum line from parsing. Parse 6-field data lines.
   - For v1: parse 5-field data lines, pad each entry with empty 6th field.
   - Remove the "newer than supported" version gate (v1 reading v2 should still fail gracefully).

6. **Update all callers of `lockfile_add_entry`** — add the 6th `integrity` argument where it is available from install results (the `compute_dir_hash` output from `Store.pmod`). Where integrity is not yet known (e.g., local deps with `-` placeholders), pass `""`.

7. **Update `lockfile_has_dep` and `merge_lock_entries`** — both work on arrays of strings and are field-count agnostic. No changes needed beyond ensuring they handle 6-field entries correctly (they already do — they access by index, not by field count).

8. **Update `prune_stale_deps`** — accesses fields by index (`e[0]`, `e[1]`, `e[2]`, `e[4]`). No changes needed; 6-field entries are compatible.

9. **Update `Verify.pmod`** — `cmd_verify` reads lockfile entries and accesses fields by index. Add integrity verification: if the `integrity` field (index 5) is non-empty, compare it against `compute_dir_hash` for the store entry. Warn on mismatch.

10. **Update filename resolution in `Project.pmod`** — `ctx["lockfile_path"]` should resolve `pmp.lock` first, then fall back to `pike.lock`. On write, target `pmp.lock`.

11. **Add tests** —
    - V2 write produces correct header, column header, 6-field lines, and valid checksum.
    - V2 read verifies checksum and rejects tampered checksum.
    - V1 lockfile is read and entries are padded to 6 fields.
    - Round-trip: write v2 → read v2 produces identical entries.
    - Filename transition: first write creates `pmp.lock` with `pike.lock` symlink.
