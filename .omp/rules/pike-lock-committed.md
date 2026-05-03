# Pike Lock Committed

**Type:** Scope-based rule
**Trigger:** Activates when `pike.json` or `.gitignore` is edited

## Scope

Matches files:
- `pike.json`
- `.gitignore`

## When triggered

### On `pike.json` edit

When dependencies in `pike.json` change, the agent **MUST**:

1. **Regenerate lockfile** — Run `sh bin/pmp install` to create/update `pike.lock`
2. **Verify pike.lock is tracked** — Ensure `pike.lock` is not gitignored
3. **Commit pike.lock** — Include lockfile changes in the same commit as dependency changes

### On `.gitignore` edit

When editing `.gitignore`, the agent **MUST NOT**:

- Re-add `pike.lock` to `.gitignore` — it should remain committed for reproducibility

## Rationale

pmp is a package manager that advocates for lockfile reproducibility. The project itself must:

- Commit `pike.lock` to git so CI can use `--frozen-lockfile`
- Never gitignore the lockfile — it enables deterministic builds

This rule prevents regressions where the lockfile gets accidentally gitignored.