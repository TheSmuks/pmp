# Source Change Documentation Sync

**Type:** Scope-based rule
**Trigger:** Activates when source files are edited

## Scope

Matches files:
- `bin/pmp.pike`
- `bin/Pmp.pmod/*.pmod`
- `tests/*.sh`

## When triggered

When editing source files, the agent **MUST**:

1. **Update `CHANGELOG.md`** — Add entry under `[Unreleased]` section documenting the change

2. **Update `ARCHITECTURE.md`** — If structural changes (new modules, changed APIs, new commands)

3. **Update `AGENTS.md`** — If test count changed (242 baseline) or architecture changes

4. **Regenerate lockfile** — If `pike.json` dependencies changed, run `sh bin/pmp install` to update `pike.lock`

## Rationale

pmp is a package manager that preaches reproducibility. The project itself must practice what it preaches:
- Lockfile committed to git for CI reproducibility
- Version sync between Config.pmod and pike.json
- Documentation kept in sync with code

This rule ensures documentation hygiene is maintained alongside code changes.