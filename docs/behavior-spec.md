# PMP Behavior Specification

Contract document for public functions in the pmp codebase.
Module paths are relative to `bin/` with subdirectories: `core/` (Semver, Source, Helpers, Config), `transport/` (Http, Resolve), `store/` (Store, StoreCmd), `project/` (Lockfile, Manifest, Project, Verify, Validate, Env), `commands/` (Install, LockOps, Update).

---

## 1. Semver (`Semver.pmod`)

### Semver.parse_semver(string tag)

**Contract**: Parse a version string into a structured mapping following Semver 2.0.0. Handles `v`/`V` prefix, prerelease suffix (`-alpha.1`), and build metadata (`+build`, which is ignored per spec).

**Determinism**: Fully deterministic.

**Inputs**:
- `tag` — any string. Empty or `0` returns `0`.

**Outputs**: `mapping` with keys `"major"` (int), `"minor"` (int), `"patch"` (int), `"prerelease"` (string), `"original"` (string). Returns `0` if the string is not valid semver.

**Edge Cases**:
- Leading zeros in numeric identifiers (e.g. `"01.2.3"`) → returns `0`.
- Partial versions (fewer than 3 parts) are rejected: `"1"` → returns `0`, `"1.2"` → returns `0`.
- Empty prerelease after `-` (e.g. `"1.0.0-"`) → returns `0`.
- Build metadata after `+` is stripped and ignored.
- `0`, `""`, absent → returns `0`.

**Failure Modes**: Returns `0` on unparseable input. Never throws or dies.

---

### Semver.compare_semver(mapping|mixed a, mapping|mixed b)

**Contract**: Compare two parsed semver mappings (as returned by `parse_semver`). Returns `-1` if a < b, `0` if equal, `1` if a > b.

**Determinism**: Fully deterministic.

**Inputs**:
- `a`, `b` — mapping from `parse_semver`, or `0` (unparseable).

**Outputs**: `int` — -1, 0, or 1.

**Edge Cases**:
- Both `0` → returns `0` (treated as equal).
- One `0` → the `0` side is less than any parsed version.
- Release vs prerelease: no prerelease (`""`) is greater than any prerelease string.
- Prerelease comparison follows semver spec: numeric identifiers < alpha identifiers, numeric compared as integers, shorter < longer on common-prefix match.

**Failure Modes**: Never throws. Handles `0` inputs by treating them as 0.0.0.

---

### Semver.sort_tags_semver(array(string) tags)

**Contract**: Sort an array of tag strings by semver, highest first. Non-semver tags sort last (lowest priority). Returns a new array (does not mutate input).

**Determinism**: Fully deterministic.

**Inputs**:
- `tags` — array of tag strings. Empty or single-element array returns a copy.

**Outputs**: `array(string)` — tags sorted highest-semver-first. Non-semver tags appear at the end in their original relative order.

**Edge Cases**:
- All tags non-semver → original order preserved.
- Empty array `({})` → returns `({})`.
- Single-element array → returns a copy.

**Failure Modes**: Never throws or dies.

---

### Semver.classify_bump(string|void old_tag, string|void new_tag)

**Contract**: Classify the version change from `old_tag` to `new_tag`.

**Determinism**: Fully deterministic.

**Inputs**:
- `old_tag`, `new_tag` — version tag strings. `void` accepted.

**Outputs**: `string` — one of `"major"`, `"minor"`, `"patch"`, `"prerelease"`, `"downgrade"`, `"none"`, or `"unknown"`.

**Edge Cases**:
- Either argument `void`/`0` → `"unknown"`.
- Either unparseable by `parse_semver` → `"unknown"`.
- `old > new` → `"downgrade"`.
- Same version → `"none"`.
- Same major.minor.patch but one has prerelease → `"prerelease"`.

**Failure Modes**: Never throws or dies. Returns `"unknown"` for invalid inputs.

---

## 2. Source (`Source.pmod`)

### Source.detect_source_type(string src)

**Contract**: Classify a source URL as `"local"`, `"github"`, `"gitlab"`, or `"selfhosted"`. Recognizes github.com and gitlab.com by default; additional hosts configurable via `PMP_GITHUB_HOSTS` and `PMP_GITLAB_HOSTS` env vars (comma-separated).

**Determinism**: Depends on environment variables `PMP_GITHUB_HOSTS`, `PMP_GITLAB_HOSTS`.

**Inputs**:
- `src` — source URL string. Prefixes `./` or `/` indicate local.

**Outputs**: `string` — `"local"`, `"github"`, `"gitlab"`, or `"selfhosted"`.

**Edge Cases**:
- Local sources (`./`, `/` prefix) return immediately without validation.
- SCP-style git URLs (`git@host:path`) are normalized before domain extraction.
- Version fragment (`#tag`) is stripped before normalization.

**Failure Modes**: Dies via `die()` if the normalized source has fewer than 3 path segments (missing `domain/owner/repo`) or if the domain contains no dot or colon.

---

### Source.source_to_name(string src)

**Contract**: Extract the module name from the last path segment of a source URL. Sanitizes hyphens and dots to underscores; strips leading/trailing underscores; collapses repeated underscores.

**Determinism**: Fully deterministic.

**Inputs**:
- `src` — source URL string.

**Outputs**: `string` — sanitized module name (e.g. `"my_lib"` from `"github.com/owner/my-lib"`).

**Edge Cases**:
- Version fragment (`#tag`) is stripped before extraction.
- Names consisting entirely of hyphens/dots (e.g. `"---"`) → dies: empty after sanitization.

**Failure Modes**: Dies via `die()` if the resulting name is empty after sanitization or if the source format is invalid.

---

### Source.source_to_version(string src)

**Contract**: Extract the version tag from the `#` fragment of a source URL. Validates the tag for path traversal and shell metacharacters.

**Determinism**: Fully deterministic.

**Inputs**:
- `src` — source URL string. May contain `#tag` fragment.

**Outputs**: `string` — the version tag, or `""` if no `#` fragment present.

**Edge Cases**:
- Multiple `#` characters: everything after the first `#` is the tag (inner `#` characters preserved).
- Empty string after `#` → returns `""` (passes validation).

**Failure Modes**: Dies via `die()` if the tag contains `..`, shell metacharacters (`;`, `|`, `&`, `$`, `` ` ``, `!`, `()`, `{}`, `<>`, `\0`, newlines, `/`, `\`, spaces), or other disallowed characters.

---

### Source.source_to_domain(string src)

**Contract**: Extract and lowercase the domain from a normalized source URL.

**Determinism**: Fully deterministic.

**Inputs**:
- `src` — source URL string.

**Outputs**: `string` — lowercased domain (first path segment after normalization).

**Edge Cases**:
- SCP-style URLs and credential-embedded URLs are normalized first.
- No validation of segment count — returns whatever the first segment is.

**Failure Modes**: Never throws or dies. Returns the first segment even if the URL is structurally incomplete.

---

### Source.source_to_repo_path(string src)

**Contract**: Extract the `owner/repo` path (everything after the domain) from a normalized source URL.

**Determinism**: Fully deterministic.

**Inputs**:
- `src` — source URL string.

**Outputs**: `string` — the path after domain (e.g. `"owner/repo"`), or `""` if fewer than 3 segments.

**Edge Cases**:
- Returns `""` if the normalized path has fewer than 3 segments.

**Failure Modes**: Dies via `die()` if source format validation fails (fewer than 3 path segments or invalid domain).

---

### Source.source_strip_version(string src)

**Contract**: Normalize a source URL and remove the `#version` fragment. Used for lockfile storage where version is stored separately.

**Determinism**: Fully deterministic.

**Inputs**:
- `src` — source URL string.

**Outputs**: `string` — normalized source without version fragment.

**Edge Cases**:
- No validation of the result — purely a normalization/stripping operation.

**Failure Modes**: Never throws or dies.

---

### Source.validate_version_tag(string tag)

**Contract**: Validate that a version tag contains no path traversal sequences (`..`), shell metacharacters, or control characters. Intended to prevent injection via tag values used in filesystem paths and git commands.

**Determinism**: Fully deterministic.

**Inputs**:
- `tag` — version tag string. Empty string passes (no-op).

**Outputs**: `void`. Returns normally if valid.

**Edge Cases**:
- Empty string is accepted (returns immediately).
- Disallowed characters: `;`, `|`, `&`, `$`, `` ` ``, `!`, `()`, `{}`, `<>`, `\0`, `\n`, `\r`, `\t`, space, `/`, `\`.

**Failure Modes**: Dies via `die()` if the tag contains any disallowed character or `..`.

---

## 3. Store (`Store.pmod`)

### Store.store_entry_name(string src, string tag, string sha)

**Contract**: Generate a deterministic store entry name from source, tag, and commit SHA. Format: `{slug}-{tag}-{sha_prefix16}` where slug is the source with `/` replaced by `-`.

**Determinism**: Fully deterministic given same inputs.

**Inputs**:
- `src` — source URL string (version fragment stripped internally).
- `tag` — version tag string.
- `sha` — commit SHA string. Must be non-empty.

**Outputs**: `string` — store entry name (e.g. `"github.com-owner-repo-v1.0.0-a1b2c3d4e5f6g7h8"`).

**Edge Cases**:
- Leading/trailing dashes in slug are trimmed.
- Repeated dashes (`--`) collapsed to single `-`.
- SHA longer than 16 chars is truncated to first 16.

**Failure Modes**: Dies via `die()` with `EXIT_INTERNAL` if `sha` is empty.

---

### Store.compute_dir_hash(string dir)

**Contract**: Compute a SHA-256 content hash of a directory by recursively collecting all regular files (sorted lexicographically), hashing each file's contents, and hashing the combined manifest. Skips `.pmp-meta` files.

**Determinism**: Fully deterministic for identical directory contents.

**Inputs**:
- `dir` — path to directory.

**Outputs**: `string` — 64-char lowercase hex SHA-256 digest.

**Edge Cases**:
- Empty directory → hash of empty manifest.
- Filenames with newlines are handled correctly (uses directory walk, not `find`).
- `.pmp-meta` files are excluded from hashing.

**Failure Modes**: Propagates `die_internal()` from `compute_sha256` if any file cannot be read.

---

### Store.read_stored_hash(string entry_dir)

**Contract**: Read the `content_sha256` field from the `.pmp-meta` metadata file of a store entry.

**Determinism**: Depends on filesystem state.

**Inputs**:
- `entry_dir` — path to a store entry directory.

**Outputs**: `string` — the stored SHA-256 hash, or `0` if the meta file is missing, unreadable, or lacks the field.

**Edge Cases**:
- If `.pmp-meta` exists but lacks the `x-pmp-end` sentinel → warns about corruption but still returns the hash if found.
- Missing `.pmp-meta` file → returns `0`.

**Failure Modes**: Returns `0` on missing/unreadable meta file. Warns on corrupt meta (missing sentinel).

---

## 4. Lockfile (`Lockfile.pmod`)

### Lockfile.merge_lock_entries(array(array(string)) existing, array(array(string)) new_entries)

**Contract**: Merge new lockfile entries into existing, deduplicating by name. New entries replace existing entries with the same name. Returns a new array.

**Determinism**: Fully deterministic.

**Inputs**:
- `existing` — array of `({name, source, tag, sha, hash})` tuples.
- `new_entries` — array of same-format tuples.

**Outputs**: `array(array(string))` — merged entries with new entries taking priority.

**Edge Cases**:
- Entries with empty name die via `die()` with `EXIT_INTERNAL`.
- Duplicate names within `new_entries`: last occurrence wins (deduplicated internally).
- Empty arrays are valid.

**Failure Modes**: Dies via `die()` with `EXIT_INTERNAL` on entries with empty name. Never throws.

---

### Lockfile.lockfile_has_dep(string name, void|string lf, void|string source)

**Contract**: Check if a dependency exists in the lockfile. Optionally verify the source matches.

**Determinism**: Depends on filesystem state (re-reads lockfile each call).

**Inputs**:
- `name` — dependency name to search for.
- `lf` — lockfile path (defaults to `"pike.lock"`).
- `source` — if provided, both name and source must match.

**Outputs**: `int` — `1` if found (with matching source if specified), `0` otherwise.

**Edge Cases**:
- If `source` is provided, returns `1` only if both name and source match.
- Missing lockfile → returns `0`.

**Failure Modes**: Returns `0` on missing/unreadable lockfile. Never throws.

---

### Lockfile.read_lockfile(void|string lf)

**Contract**: Read and parse a lockfile into structured entries. Validates format version.

**Determinism**: Depends on filesystem state.

**Inputs**:
- `lf` — lockfile path (defaults to `"pike.lock"`).

**Outputs**: `array(array(string))` — array of `({name, source, tag, sha, hash})` tuples, in file order.

**Edge Cases**:
- Missing or empty file → returns `({})`.
- Lines with fewer than 5 tab-separated fields or empty name → skipped with warning.
- Windows line endings (`\r`) are normalized.
- Lockfile version newer than `LOCKFILE_VERSION` → dies with update message.
- Missing version header but file contains tab-separated data → warns.
- Invalid (non-numeric) version string → dies.

**Failure Modes**: Dies via `die()` if lockfile format version is newer than supported or version string is invalid. Returns `({})` for missing/empty files. Warns and skips malformed lines.

---

### Lockfile.write_lockfile(string lockfile_path, array(array(string)) entries)

**Contract**: Write lockfile entries to disk atomically (temp file + rename). Backs up existing lockfile to `.prev`. Validates field integrity before writing.

**Determinism**: Fully deterministic for given inputs.

**Inputs**:
- `lockfile_path` — destination file path.
- `entries` — array of `({name, source, tag, sha, hash})` tuples.

**Outputs**: `void`.

**Edge Cases**:
- Each entry must have at least 5 fields.
- Name field (entry[0]) must be non-empty.
- No field may contain tab, newline, or carriage return characters.
- Falls back to copy+rm if `mv` fails (cross-filesystem).

**Failure Modes**: Dies via `die()` with `EXIT_INTERNAL` if entries have fewer than 5 fields, empty name, or fields containing tab/newline/CR. Dies if both `mv` and copy fallback fail.

---

## 5. Helpers (`Helpers.pmod`)

### Helpers.atomic_symlink(string target, string dest)

**Contract**: Atomically create or replace a symlink at `dest` pointing to `target`. Uses temp symlink + `rename(2)` so there is no window where `dest` is missing. If `dest` is a real directory (not a symlink), removes it first.

**Determinism**: Depends on filesystem state.

**Inputs**:
- `target` — symlink target path.
- `dest` — symlink destination path.

**Outputs**: `void`.

**Edge Cases**:
- If `dest` is a real directory (not a symlink), it is recursively removed before symlink creation.
- Temp link name includes PID, timestamp, and 64-bit random for uniqueness.
- Leftover temp links from crashes are cleaned up before creation attempt.

**Failure Modes**: Dies via `die()` with `EXIT_INTERNAL` if symlink creation or rename fails.

---

### Helpers.compute_sha256(string path)

**Contract**: Compute SHA-256 hex digest of a file using streaming reads (64KB chunks) to avoid loading entire file into memory.

**Determinism**: Fully deterministic for identical file contents.

**Inputs**:
- `path` — path to a regular file.

**Outputs**: `string` — 64-char lowercase hex SHA-256 digest.

**Edge Cases**:
- Non-regular files (directories, symlinks) → dies.
- File handle is closed even on read error.

**Failure Modes**: Dies via `die_internal()` if path is not a regular file, file cannot be opened, or a read error occurs.

---

### Helpers.find_project_root(void|string dir)

**Contract**: Walk up from a directory to find the nearest parent containing `pike.json`.

**Determinism**: Depends on filesystem state.

**Inputs**:
- `dir` — starting directory (defaults to `getcwd()`).

**Outputs**: `string` — absolute path to the directory containing `pike.json`, or `0` if not found.

**Edge Cases**:
- Walks up to filesystem root `/`. Returns `0` if no `pike.json` found.
- Handles symlink cycles via `combine_path(d, "..")` equality check.

**Failure Modes**: Returns `0` if no `pike.json` is found. Never throws.

---

## 6. Manifest (`Manifest.pmod`)

### Manifest.parse_deps(string file)

**Contract**: Parse dependencies from a `pike.json` file. Returns sorted array of `{name, source}` pairs.

**Determinism**: Depends on filesystem state.

**Inputs**:
- `file` — path to `pike.json`. Required.

**Outputs**: `array(array(string))` — sorted by name. Each element is `({name, source_string})`.

**Edge Cases**:
- Missing file → returns `({})`.
- Unreadable file → returns `({})`.
- Malformed JSON → returns `({})`.
- Missing or non-mapping `dependencies` key → returns `({})`.
- Dependencies with non-string or empty values are silently skipped.

**Failure Modes**: Returns `({})` on all error conditions. Never throws or dies.

---

### Manifest.add_to_manifest(string pike_json, string name, string source)

**Contract**: Add or update a dependency in a `pike.json` manifest file. Writes atomically (temp file + rename).

**Determinism**: Fully deterministic for given inputs.

**Inputs**:
- `pike_json` — path to `pike.json`.
- `name` — dependency name.
- `source` — dependency source URL.

**Outputs**: `void`.

**Edge Cases**:
- Missing `pike.json` → warns and returns.
- Unreadable or malformed JSON → warns and returns.
- Top-level JSON not an object → warns and returns.
- Dependency already present with same source → no-op.
- Dependency already present with different source → updates and logs the change.
- Creates `dependencies` mapping if absent.

**Failure Modes**: Warns and returns on missing/unreadable/malformed files. Dies via `die()` with `EXIT_INTERNAL` if atomic write fails.

---

## 7. Resolve (`Resolve.pmod`)

### Resolve.latest_tag(string type, string domain, string repo_path, void|string version)

**Contract**: Resolve the latest (highest semver) tag for a repository.

**Determinism**: Depends on external state (remote API/git).

**Inputs**:
- `type` — `"github"`, `"gitlab"`, or `"selfhosted"`.
- `domain` — host domain (used for `"selfhosted"`, ignored for github/gitlab).
- `repo_path` — `owner/repo` path.
- `version` — optional pmp version for user-agent header.

**Outputs**: `array(string)` — `({tag_name, commit_sha})`. Both may be `""` if no tags found.

**Edge Cases**:
- No tags found → returns `({"", ""})`.

**Failure Modes**: Dies via `die()` for unknown source type. Individual backends die on API parse failures (first page only) and warn on subsequent pages.

---

### Resolve.resolve_commit_sha(string type, string domain, string repo_path, string tag, void|string version)

**Contract**: Resolve a specific tag to its commit SHA.

**Determinism**: Depends on external state (remote API/git).

**Inputs**:
- `type` — `"github"`, `"gitlab"`, or `"selfhosted"`.
- `domain` — host domain.
- `repo_path` — `owner/repo` path.
- `tag` — version tag string.
- `version` — optional pmp version for user-agent header.

**Outputs**: `string` — 40-char hex commit SHA, or `0` if unresolvable.

**Edge Cases**:
- GitHub: uses commits API endpoint.
- GitLab: URL-encodes the repo path (`/` → `%2F`), reads `id` field.
- Self-hosted: uses `git ls-remote`; prefers dereferenced tag lines (`^{}`) for annotated tags; validates SHA is hex and >= 7 chars.

**Failure Modes**: Returns `0` if the SHA cannot be resolved (API error, tag not found, non-hex SHA). Dies via `die()` for unknown source type.

---

## 8. Http (`Http.pmod`)

### Http.http_get(string url, void|mapping(string:string) headers, void|string version)

**Contract**: Perform an HTTP GET request. Dies on any error (connection failure, non-200 status, empty body). Provides specific error messages for 401/403 from GitHub (token guidance).

**Determinism**: Depends on external state (network).

**Inputs**:
- `url` — HTTP(S) URL string.
- `headers` — optional additional request headers.
- `version` — optional pmp version string (defaults to `"0.2.0"`).

**Outputs**: `string` — response body on success (status 200 with non-empty body).

**Edge Cases**:
- Error messages include only the host, not the full URL (tokens may appear in URLs in future).
- GitHub 401/403: provides specific guidance about `GITHUB_TOKEN` setup.

**Failure Modes**: Dies via `die()` on connection failure, non-200 status, or empty body. Specific messaging for auth errors.

---

### Http.http_get_safe(string url, void|mapping(string:string) headers, void|string version)

**Contract**: Perform an HTTP GET request without dying. Returns status and body as a tuple. Handles redirects, body size limits, and redirect security.

**Determinism**: Depends on external state (network).

**Inputs**:
- `url` — HTTP(S) URL string.
- `headers` — optional additional request headers.
- `version` — optional pmp version string (defaults to `"0.2.0"`).

**Outputs**: `array(int|string)` — `({status_code, body_string})`. Status `0` indicates a client-side error (timeout, connection failure, security block), with body containing an error description.

**Edge Cases**:
- Up to 5 HTTP redirects followed. Redirects must stay on same domain or subdomain.
- HTTPS-to-HTTP downgrade redirects are blocked.
- Non-HTTP scheme redirects are blocked (prevents `file:///etc/passwd`).
- Response bodies exceeding `HTTP_MAX_BODY_SIZE` (default 100 MB) are rejected.
- Retries transient failures (429, 5xx, connection errors) with exponential backoff + jitter (max `HTTP_MAX_RETRIES`, default 3).
- 429 respects `Retry-After` header.

**Failure Modes**: Returns `({0, "error description"})` for timeout, connection error, security block, or body size limit. Never dies.

---

## 9. Config (`Config.pmod`)

### Constants

| Constant | Type | Value | Description |
|---|---|---|---|
| `PMP_VERSION` | string | `"0.4.0"` | Current pmp version |
| `EXIT_OK` | int | `0` | Successful exit |
| `EXIT_ERROR` | int | `1` | User error (invalid input, missing deps, usage) |
| `EXIT_INTERNAL` | int | `2` | Internal error (invariant violation, store corruption) |
| `PMP_VERBOSE` | int | `(int)(getenv("PMP_VERBOSE") \|\| "0")` | Verbosity level (env-configurable) |
| `PMP_QUIET` | int | `(int)(getenv("PMP_QUIET") \|\| "0")` | Suppress non-error output (env-configurable) |

### Mutators

- `set_verbose(int v)` — override `PMP_VERBOSE` programmatically.
- `set_quiet(int v)` — override `PMP_QUIET` programmatically.

---

## 10. Http Configuration Constants

| Constant | Type | Default | Description |
|---|---|---|---|
| `HTTP_CONNECT_TIMEOUT` | int | `10` | Connect timeout in seconds |
| `HTTP_READ_TIMEOUT` | int | `30` | Read timeout in seconds |
| `HTTP_MAX_RETRIES` | int | `3` | Max retries for transient failures |
| `HTTP_MAX_BODY_SIZE` | int | `104857600` | Max response body size in bytes (100 MB) |

---

## Cross-Cutting Concerns

### Locking Protocol

Both store and project locks use O_EXCL (`"wxc"` mode) for atomic lock file creation. Both detect stale locks by checking if the PID in the lock file is alive via `kill -0`. Backoff uses exponential delay with jitter. Lock cleanup is registered via `register_store_lock`/`register_project_lock` and executed by `run_cleanup()` on signal or exit.

### Atomic Writes

All file writes that must not be corrupted by crashes use the temp-file-then-rename pattern:
1. Write to `<path>.tmp.<pid>` (or similar unique suffix).
2. `mv()` (wraps `rename(2)`) to final path.
3. If `mv` fails (cross-filesystem), fall back to copy + rm.

### Error Signaling Convention

| Signal | Used When |
|---|---|
| `die(msg)` | User errors (invalid input, missing deps) — exit code 1 |
| `die(msg, EXIT_INTERNAL)` | Internal errors (invariant violations, corruption) — exit code 2 |
| `die_internal(msg)` | Alias for `EXIT_INTERNAL` exit — always exit code 2 |
| Return `0` | Missing/unparseable data where failure is expected (e.g. no lockfile) |
| Return `({})` | Empty result for missing/malformed input files |
| `warn(msg)` | Non-fatal issues that should be surfaced to the user |
