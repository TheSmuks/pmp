# PMP Behavior Specification

Documents the contract of every public function across all modules.
For each function: contract, valid inputs, edge cases, failure modes.

---

## Config.pmod

Constants only. No testable functions.

| Symbol | Value | Purpose |
|--------|-------|---------|
| `PMP_VERSION` | `"0.4.0"` | Current version string |
| `EXIT_OK` | `0` | Success exit code |
| `EXIT_ERROR` | `1` | User error exit code |
| `EXIT_INTERNAL` | `2` | Internal error exit code |
| `PMP_VERBOSE` | variable | Verbose output flag |
| `PMP_QUIET` | variable | Quiet output flag |

---

## Helpers.pmod

### `die(string msg, int|void exit_code)`
- **Contract**: Writes `pmp: <msg>` to stderr, calls `exit(exit_code || EXIT_ERROR)`. Never returns.
- **Side effects**: Calls `run_cleanup()` before exit.
- **Failure modes**: None — always terminates the process.

### `die_internal(string msg)`
- **Contract**: Like `die()` but uses `EXIT_INTERNAL` (2). For assertion-style failures.

### `info(string msg)`
- **Contract**: Writes `pmp: <msg>` to stdout unless `PMP_QUIET` is set.
- **Returns**: void.

### `warn(string msg)`
- **Contract**: Writes `pmp: warning: <msg>` to stderr unless `PMP_QUIET` is set.

### `debug(string msg)`
- **Contract**: Writes `pmp: <msg>` to stdout only if `PMP_VERBOSE` is set.

### `need_cmd(string cmd)`
- **Contract**: Dies if `cmd` is not found in PATH.
- **Valid input**: Non-empty string command name.

### `json_field(string path, string field)`
- **Contract**: Reads JSON file at `path`, returns value of `field` as string. Returns 0 if field missing or file invalid.
- **Valid inputs**: Path to JSON file, field name string.
- **Edge cases**: Malformed JSON returns 0 with warning. Missing file returns 0 with warning.

### `find_project_root()`
- **Contract**: Walks up from cwd to find directory containing `pike.json`. Returns path or 0.
- **Edge cases**: Returns 0 at filesystem root. Returns absolute path.

### `compute_sha256(string path)`
- **Contract**: Computes SHA-256 of file at `path` using streaming (64KB chunks). Returns hex string.
- **Failure modes**: Dies on unreadable file.

### `atomic_symlink(string target, string dest)`
- **Contract**: Creates symlink at `dest` pointing to `target` atomically (temp link + rename).
- **Failure modes**: Dies on symlink failure.

### `run_with_timeout(array(string) args, int timeout_secs, void|mapping env)`
- **Contract**: Runs subprocess with timeout. Returns `(["exitcode": int, "stdout": string, "stderr": string])`.
- **Timeout behavior**: Returns `exitcode: -1` on timeout, with partial stdout/stderr.
- **Pipe handling**: Reads stdout and stderr concurrently via threads to avoid >64KB deadlock.
- **Valid inputs**: Non-empty command array, positive timeout.

---

## Source.pmod

### `detect_source_type(string src)`
- **Contract**: Returns `"local"`, `"github"`, `"gitlab"`, or `"selfhosted"`.
- **Valid inputs**: URLs, local paths (./, /).
- **Edge cases**: Dies on invalid format (fewer than 3 path segments for non-local).
- **Environment**: `PMP_GITHUB_HOSTS`, `PMP_GITLAB_HOSTS` extend host detection.

### `source_to_name(string src)`
- **Contract**: Extracts module name from last path segment. Filters empty segments (handles trailing slashes).
- **Edge cases**: Dies on empty path after filtering.

### `source_to_version(string src)`
- **Contract**: Extracts version from `#suffix`. Empty string if none.
- **Side effects**: Calls `validate_version_tag()` on extracted tag.

### `source_to_domain(string src)`
- **Contract**: Extracts domain (lowercase) from normalized source.

### `source_to_repo_path(string src)`
- **Contract**: Extracts `owner/repo` path. Dies on invalid format.

### `source_strip_version(string src)`
- **Contract**: Normalizes source and removes `#version`. Returns clean `host/owner/repo`.

### `validate_version_tag(string tag)`
- **Contract**: Dies if tag contains path traversal (`..`), shell metacharacters, null bytes, whitespace, or slashes.
- **Valid input**: Semver-compatible strings like `v1.2.3`, `1.2.3-alpha.1`.
- **Edge cases**: Empty string is allowed (no tag pinned).

---

## Semver.pmod

### `parse_semver(string tag)`
- **Contract**: Parses version string into `(["major": int, "minor": int, "patch": int, "prerelease": string, "original": string])`. Returns 0 if not parseable.
- **Valid inputs**: `"1.2.3"`, `"v1.2.3"`, `"1.2.3-alpha"`, `"1.2.3-alpha.1+build"`.
- **Edge cases**:
  - `""`, `0`, null → returns 0
  - `"1.2.3-"` → returns 0 (empty prerelease per spec §9)
  - `"1"` → single part (treated as `1.0.0`)
  - `"1.2"` → two parts (treated as `1.2.0`)
  - Leading zeros (`"01.2.3"`) → returns 0
  - Build metadata (`+suffix`) → stripped and ignored

### `compare_semver(mapping a, mapping b)`
- **Contract**: Returns -1/0/1. Unparseable (0) sorts below everything.
- **Ordering**: major > minor > patch > prerelease. Release > prerelease.

### `compare_prerelease(string a, string b)`
- **Contract**: Per semver spec: numeric < alpha, numeric compared as int, alpha compared lexically. Empty (release) > any prerelease.

### `sort_tags_semver(array(string) tags)`
- **Contract**: Sorts tags highest semver first. Non-semver tags sort last. Returns new array.

### `classify_bump(string old_tag, string new_tag)`
- **Contract**: Returns `"major"`, `"minor"`, `"patch"`, `"prerelease"`, `"downgrade"`, `"none"`, or `"unknown"`.
- **Edge cases**: Unparseable versions return `"unknown"`.

---

## Http.pmod

### `http_get(string url, void|mapping headers, void|string version)`
- **Contract**: Performs HTTP GET, dies on failure (non-200, timeout). Returns body string.
- **Error messages**: Include host (not full URL). Include specific failure reason.
- **Retries**: Up to `HTTP_MAX_RETRIES` (3) with exponential backoff + jitter.
- **Environment**: `GITHUB_TOKEN`, `HTTPS_PROXY`, timeout env vars.

### `http_get_safe(string url, void|mapping headers, void|string version)`
- **Contract**: Returns `({ int status, string body })`. Status 0 means failure (body contains reason).
- **Failure reasons**: `"timeout or connection error"`, `"redirect to non-HTTP scheme blocked"`, `"HTTPS to HTTP redirect blocked"`, `"redirect domain mismatch"`, `"response body exceeds size limit"`, `"redirect limit exceeded"`.
- **Max redirects**: 5.
- **Body size limit**: 100 MB (checked after full response — known limitation).

### `github_auth_headers()`
- **Contract**: Returns `(["authorization": "token <GITHUB_TOKEN>"])` or 0 if no token set.

### `gitlab_auth_headers()`
- **Contract**: Returns `(["private-token": "<GITLAB_TOKEN>"])` or 0 if no token set.

---

## Resolve.pmod

### `latest_tag_github(string repo_path, void|string version)`
- **Contract**: Returns `({ tag, sha })`. Paginates through all GitHub tags.
- **Failure modes**: Dies on JSON parse failure from page 1 (API error, rate limit). Later page failures break gracefully.
- **Caching**: Results cached in memory per repo.

### `latest_tag_gitlab(string repo_path, void|string version)`
- **Contract**: Same as `latest_tag_github` for GitLab API.

### `latest_tag_selfhosted(string domain, string repo_path)`
- **Contract**: Uses `git ls-remote --tags`. Returns `({ tag, sha })` or `({"", ""})` on failure.

### `resolve_commit_sha(string type, string domain, string repo_path, string tag, void|string version)`
- **Contract**: Returns commit SHA string or 0 on failure.
- **Failure modes**: Returns 0 (never dies) for unresolvable SHAs.

---

## Store.pmod

### `store_entry_name(string source, string tag, string sha)`
- **Contract**: Generates `{domain}-{owner}-{repo}-{tag}-{sha_prefix_16}` format name.
- **Edge cases**: Empty SHA dies. Long SHA truncated to 16 chars.

### `extract_targz(string archive, string dest)`
- **Contract**: Extracts tar.gz archive to dest directory. Uses `--no-same-owner --no-same-permissions`.
- **Security**: Validates extracted paths (no symlink traversal).

### `write_meta(string entry_dir, mapping fields)`
- **Contract**: Writes `.pmp-meta` file atomically (tmp + rename).
- **Valid fields**: `commit_sha`, `content_sha256`, `tarball_sha256`, `source`, `tag`, `installed_at`.

### `compute_dir_hash(string dir)`
- **Contract**: Computes SHA-256 over all files in directory (sorted, streaming).

### `read_stored_hash(string entry_dir)`
- **Contract**: Reads `content_sha256` from `.pmp-meta`. Returns string or 0.

### `_read_meta_field(string entry_dir, string field)`
- **Contract**: Reads a single field from `.pmp-meta`. Returns string or 0.

### `store_install_github/gitlab/selfhosted(store_dir, ...)`
- **Contract**: Downloads tarball, extracts to store, writes meta. Returns `(["entry": string, "tag": string, "sha": string, "hash": string])`.
- **Locking**: Uses O_EXCL lock during install.

---

## Lockfile.pmod

### `lockfile_add_entry(array entries, string name, string source, string tag, string sha, string hash)`
- **Contract**: Appends entry to array. Returns new array (Pike `+=` creates new).
- **Format**: `name\tsource\ttag\tsha\thash`

### `write_lockfile(string path, array entries)`
- **Contract**: Writes lockfile atomically (tmp + rename). Prepends version header. Validates entries.
- **Validation**: Rejects tabs and newlines in field values. Rejects entries with <5 fields.

### `read_lockfile(string path)`
- **Contract**: Reads lockfile into array of `({name, source, tag, sha, hash})` tuples.
- **Validation**: Warns on missing version header. Skips malformed lines.
- **Edge cases**: Empty file returns `({})`. Non-existent file returns `({})`.

### `lockfile_has_dep(string name, array lf, void|string source)`
- **Contract**: Returns 1 if dep exists in lockfile. Optionally verifies source URL matches.

### `merge_lock_entries(array existing, array new)`
- **Contract**: Deduplicates by name. New entries replace existing with same name. Uses multiset for O(n) lookup.

### `project_lock/project_unlock(string project_root)`
- **Contract**: Advisory file lock at `<project_root>/.pmp-install.lock`. Contains PID. Detects stale locks via `kill -0`.
- **Retry**: Up to 10 attempts with exponential backoff + jitter.

---

## Manifest.pmod

### `add_to_manifest(string pike_json, string name, string source)`
- **Contract**: Adds dependency to `pike.json` dependencies section. Atomic write (tmp + rename).
- **Edge cases**: Dies if pike.json doesn't exist. Preserves existing deps.

### `parse_deps(string pike_json)`
- **Contract**: Reads `pike.json` and returns `({ ({name, source}), ... })` array.
- **Edge cases**: Returns `({})` on missing file or empty dependencies.

---

## Install.pmod

### `install_one(string name, string source, string target, mapping ctx)`
- **Contract**: Installs single dep including transitive resolution. Updates `ctx["lock_entries"]` and `ctx["visited"]`.
- **Cycle detection**: Uses visited-set (`ctx["visited"]`).
- **Offline mode**: Skips SHA resolution when `ctx["offline"]` is set and stored SHA is missing.
- **Force mode**: When `ctx["force"]`, replaces existing version.

### `cmd_install(array args, mapping ctx)`
- **Contract**: Entry point for `pmp install`. Handles flags, delegates to `cmd_install_all` or `cmd_install_source`.

### `cmd_install_all(string target, mapping ctx)`
- **Contract**: Installs all deps from pike.json. Atomic install (staging dir + swap). Lockfile management.
- **Atomic install**: Creates staging dir, installs to it, swaps atomically with modules/.

### `cmd_update(array args, mapping ctx)`
- **Contract**: Updates deps. Single-module path has catch for lock release on failure.

### `cmd_rollback(mapping ctx)`
- **Contract**: Restores modules from `pike.lock.prev`. Validates .prev entries against store before restoring.
- **Edge cases**: Skips entries with missing store entries. Dies if no valid entries.

### `cmd_changelog(array args, mapping ctx)`
- **Contract**: Shows commit log between current and previous lockfile versions for a module.

### `print_update_summary(array old, array new)`
- **Contract**: Prints old→new version comparison table.

---

## Project.pmod

### `cmd_init(mapping ctx)`
- **Contract**: Creates `pike.json` with empty dependencies. Verifies write success.

### `cmd_list(array args, mapping ctx)`
- **Contract**: Lists installed dependencies with column headers.

### `cmd_clean(mapping ctx)`
- **Contract**: Removes `./modules/` directory. Reports summary.

### `cmd_remove(array args, mapping ctx)`
- **Contract**: Removes a dependency. Path traversal protection on module name.

---

## Env.pmod

### `cmd_env(mapping ctx)`
- **Contract**: Creates `.pike-env/` with pike wrapper and activate script.
- **Security**: Single-quotes path values to prevent shell injection. Rejects newlines in paths.

### `build_paths(mapping ctx)`
- **Contract**: Returns `({ mod_paths, inc_paths })` from project and global dirs.

### `cmd_run(array args, mapping ctx)`
- **Contract**: Runs script with module paths set. Dies if pike binary invalid.

### `cmd_resolve(array args, mapping ctx)`
- **Contract**: Prints resolved module paths.

---

## Verify.pmod

### `cmd_verify(mapping ctx)`
- **Contract**: Returns 1 if all checks pass, 0 if issues found.
- **Checks**:
  1. Symlink health (valid, broken, skipped non-symlink)
  2. Store entry integrity (content hash verification)
  3. Lockfile consistency (missing entries, orphaned modules)
  4. Orphaned store entries (informational only)

### `cmd_doctor(mapping ctx)`
- **Contract**: Checks pike binary, git, tokens, store, disk. Returns 1/0.

---

## StoreCmd.pmod

### `cmd_store(array args, mapping ctx)`
- **Contract**: Shows store entries and disk usage. `store prune [--force]` removes unreferenced entries.
- **--dry-run**: Only `store prune` implements dry-run (lists entries without deleting).

---

## Adversarial Test Categories

For every function, test these vectors:
1. **Empty input**: `""`, `({})`, `([])`
2. **Null bytes**: strings containing `"\0"`
3. **Type confusion**: int where string expected
4. **Oversized input**: 10MB string, 10000-element array
5. **Unicode**: non-ASCII in URLs, tags, module names
6. **Shell metacharacters**: `$()`, backticks, `;`, `|`, `>` in string fields
7. **Path traversal**: `../`, absolute paths, symlinks in path inputs
8. **Concurrency**: two processes writing same lockfile
9. **Partial failure**: disk full mid-write, network timeout mid-download
