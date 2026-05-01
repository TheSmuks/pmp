# 0005: Workspace (Monorepo) Support

**Status**: Proposed
**Date**: 2026-04-30
**Decision Maker**: @TheSmuks

## Context

pmp currently manages a single project: one `pike.json`, one lockfile, one set of dependencies. Users with monorepo structures — multiple related Pike packages in one repository — must manage each `pike.json` independently. This means running `pmp install` per member, maintaining separate lockfiles, and having no way to share dependency versions or deduplicate across members.

This is the same problem Cargo, npm, and Go workspaces solve: coordinated dependency management across multiple packages in a single repository.

## Decision

Follow the Cargo workspace model adapted for pmp's conventions.

### Workspace Manifest

The root `pike.json` declares workspace membership via glob patterns:

```json
{
  "name": "my-monorepo",
  "workspace": ["packages/*"],
  "dependencies": {
    "shared-dep": "github.com/org/dep#v1.0.0"
  }
}
```

- `workspace` is an array of glob patterns expanded relative to the root `pike.json`.
- Each expanded path that contains a `pike.json` is a workspace member.
- Root `dependencies` are inherited by all members (overridable per-member).
- Members depend on each other via path references: `"../auth"` or `"./sibling"`.

### Discovery and Resolution

1. `find_project_root` walks upward from cwd until it finds a `pike.json` with a `workspace` field — that is the workspace root.
2. Members are discovered by expanding globs and confirming each path has a `pike.json`.
3. A single shared lockfile at the workspace root records all resolved versions, tagged with their originating member.
4. Dependency resolution merges all member dependency graphs, detecting conflicts at resolve time.

### Commands

| Command | Behavior at root | Behavior in member |
|---|---|---|
| `pmp install` | Install for all members | Install just that member (lockfile still at root) |
| `pmp list` | Show all members and their dependencies | Show that member's dependencies |
| `pmp run` | Requires `--package` flag to select member | Runs script from that member's `pike.json` |
| `pmp update` | Update across entire workspace | Update only that member's dependencies |

### Implementation Approach

1. **`Workspace.pmod`** in `bin/Pmp.pmod/` — workspace discovery, member resolution, and dependency graph merging.
2. **`find_project_root`** gains workspace awareness — detects `workspace` field and returns root metadata.
3. **Lockfile v2** records per-member origin for each resolved dependency, enabling selective install/update.
4. **Dependency resolution** merges member graphs; version conflicts are errors, not silent overrides.

## Implementation Steps

1. Add `workspace` field parsing to project root detection (`find_project_root` / `Project.pmod`).
2. Implement `Workspace.pmod` with glob expansion and member discovery.
3. Extend lockfile format to record workspace member origin per entry (requires lockfile v2).
4. Add dependency graph merging across members with conflict detection.
5. Wire `pmp install` to handle root (all members) vs member (single) modes.
6. Wire `pmp list`, `pmp run --package`, and `pmp update` for workspace context.
7. Add integration tests: multi-member workspace, cross-member path deps, version conflicts.

## Dependencies

- **US-502 (Lockfile v2)** — The lockfile must support structured per-entry metadata before it can record workspace member origins. Workspace support cannot ship without this.
- **US-504 (Semver Ranges)** — Workspace dependency merging requires range resolution to detect conflicts and pick compatible versions. Must land first or concurrently.

## Consequences

### Positive

- Monorepo users get coordinated dependency management with a single lockfile.
- Cross-member path dependencies replace ad-hoc relative-path hacks.
- Shared store deduplicates identical dependencies across members.
- `pmp install` at root is a single operation for the entire repository.

### Negative

- Significant implementation scope — new module, lockfile format change, command-level branching logic.
- Dependency conflict resolution across members can be surprising: a member's dependency may be pinned to a version it didn't choose because a sibling required a different range.
- `find_project_root` becomes more complex — must distinguish workspace root from standalone project root.
- Error messages must clearly indicate which member caused a conflict.

### Neutral

- Workspace is opt-in: projects without a `workspace` field behave exactly as today.
- Path dependencies between members follow the same resolution path as external dependencies — no special casing at the install layer.

## Alternatives Considered

### Separate pmp invocations per member

Status quo. Rejected because it duplicates lockfiles, prevents version deduplication, and forces users to write shell scripts for cross-member operations.

### Recursive pike.json with nested `workspace` fields

Allow workspaces inside workspaces. Rejected because it adds significant complexity (diamond dependencies, conflicting lockfile ownership) without a clear use case. Flat workspace membership is sufficient and simpler to reason about.

### Symlink-based monorepo

Use symlinks to share a `pike_modules` directory across members. Rejected because it bypasses dependency resolution, provides no version conflict detection, and breaks `pike.json` as the single source of truth.
