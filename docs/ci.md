# CI Architecture Guide

## Overview

pmp uses separate GitHub Actions workflow files, one concern per file. Each workflow owns a single responsibility and can be enabled, disabled, or overridden independently.

| Workflow | Purpose | Trigger |
|---|---|---|
| `ci.yml` | Pike syntax check + test suite | push to main, PRs |
| `release.yml` | Create GitHub release + tag | tag push (v*) |
| `docs-check.yml` | Verify doc sync (AGENTS.md, ARCHITECTURE.md, SKILL.md) | PRs |
| `commit-lint.yml` | Conventional commit enforcement | push to main, PRs |
| `changelog-check.yml` | Require CHANGELOG.md updates | PRs |
| `blob-size-policy.yml` | Reject files >1MB | PRs |

## Workflow Design Principles

- **Independently disableable.** A failing commit-lint does not block test runs.
- **Overridable.** Teams can replace `ci.yml` while keeping policy workflows intact.
- **Least privilege.** Every workflow declares `permissions: contents: read`.
- **Concurrency control.** Each workflow cancels superseded runs for the same ref.

## Adding New Checks

- **Project-specific checks** (coverage, deploy) go in `ci.yml`.
- **Cross-cutting policy** (commit style, changelog, file size limits) gets its own workflow file.
- All workflows must have `permissions: contents: read` and a `concurrency` group.

## Local Verification

Before pushing, run:

```bash
# Full test suite
sh tests/runner.sh

# Or via the backwards-compat shim
sh tests/test_install.sh

# Pike unit tests
sh tests/pike_tests.sh

# Syntax check
pike bin/pmp.pike --help
```

## References

- [Conventional Commits](https://www.conventionalcommits.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
