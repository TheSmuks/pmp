# Contributing to PMP

## Development Setup

### Prerequisites
- Pike 8.0+

### Running Tests
`sh tests/runner.sh` or `sh tests/test_install.sh`

## How to Contribute

1. Fork the repository
2. Create a feature branch (see [Branch Naming](#branch-naming))
3. Make your changes
4. Run the test suite and ensure all tests pass
5. Commit with conventional commits (see below)
6. Update [CHANGELOG.md](./CHANGELOG.md) under `[Unreleased]`
7. Push and open a Pull Request

## Branch Naming

Follow [Conventional Branch](https://github.com/nickshanks347/conventional-branch) naming:

```
<type>/<short-description>
```

| Type | Use for |
|------|----------|
| `feature/`, `feat/` | New functionality |
| `bugfix/`, `fix/` | Bug fixes |
| `hotfix/` | Urgent production fixes |
| `chore/` | Maintenance, deps, tooling |
| `docs/` | Documentation only |
| `refactor/` | Code restructuring without behavior change |
| `test/` | Adding or updating tests |
| `ci/` | CI/CD pipeline changes |
| `release/` | Release preparation |

Rules:

- Lowercase only
- Use hyphens (not underscores) to separate words
- Keep descriptions short and descriptive

## Commit Conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/) 1.0.0:

    <type>(<scope>): <description>

Types: feat, fix, docs, refactor, test, chore, ci, perf, style, revert

Scopes: install, store, lockfile, deps, env, cli

### Breaking Changes

Include `BREAKING CHANGE:` in the footer or add `!` after the type.

## Changelog

Update [CHANGELOG.md](./CHANGELOG.md) under the `[Unreleased]` section for every user-facing change.

## Pull Request Guidelines

- Keep PRs focused on a single change
- Include tests for new features
- Update documentation (CHANGELOG.md, README.md) as needed
- Ensure CI passes
- Follow the PR template when opening a PR

## Code Review

All PRs require review before merge. Reviewers check for:
- Correctness and edge case handling
- Test coverage
- Documentation accuracy
- Consistent code style
