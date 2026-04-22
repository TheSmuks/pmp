# Release Process

## Version bump

1. Update `PMP_VERSION` in `bin/Pmp.pmod/Config.pmod`
2. Commit all changes
3. Tag the release: `git tag vX.Y.Z`
4. Push tag: `git push origin vX.Y.Z`

## Pre-release checklist

- Run `sh tests/test_install.sh` — all tests must pass (see AGENTS.md for current count)
- Update `CHANGELOG.md` — move relevant items from `[Unreleased]` to a new version section
- Run `sh bin/pmp --help` — syntax check must pass
- Run `sh tests/pike_tests.sh` — all Pike tests must pass
- Verify AGENTS.md and ARCHITECTURE.md are synchronized (see below)

## Documentation maintenance protocol

When any change lands on `main` that modifies:

- **Public API** (new commands, changed flags, changed output format)
- **File structure** (new files, renamed files, removed files)
- **Test baseline** (new tests, changed counts)
- **Architecture** (new source types, changed install flow, new commands)

The following MUST be updated in the same commit:

1. **AGENTS.md** — project overview, architecture list, setup commands, expected test baseline
2. **ARCHITECTURE.md** — project structure tree, component descriptions, data flow diagram

**Doc-only changes** (comment rewrites, typo fixes) do NOT require a full doc sweep.

**Version bumps** MUST verify all three docs reflect the new version.
