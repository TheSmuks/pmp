# 0001: Adopt ai-project-template

**Status**: Accepted
**Date**: 2026-04-21
**Decision Maker**: @TheSmuks

## Context

pmp needed consistent project scaffolding: CI workflows, issue templates, code review agents, and documentation conventions. The ai-project-template provides these as a reusable starting point with an incremental adoption path.

The template provides:
- GitHub Actions workflows for commit linting, changelog enforcement, and blob size policies
- Issue and PR templates for structured contributions
- OMP agent definitions for code review, changelog updates, and ADR writing
- Project configuration files (.editorconfig, .gitattributes, .architecture.yml)

## Decision

Adopt ai-project-template v0.2.0 into the pmp repository, adapting files for Pike conventions.

**MUST**:
- Keep all existing pmp-specific content (AGENTS.md project overview, ARCHITECTURE.md, test suite)
- Adapt template files for Pike (code reviewer knows Pike syntax, PR template references pmp test commands)
- Track the adopted template version in `.template-version`

**SHOULD**:
- Update AGENTS.md with the CI table from the template
- Add the changelog badge to README.md

**MAY**:
- Omit files that don't apply (devcontainer, SETUP_GUIDE, AI/ML gitignore patterns)

## Consequences

### Positive

- Consistent CI/CD policies across projects using the template
- Structured issue/PR templates improve contribution quality
- OMP agents automate code review and changelog maintenance
- `.editorconfig` and `.gitattributes` enforce consistent formatting

### Negative

- Additional workflow files increase CI run time slightly (commit-lint, changelog-check, blob-size-policy)
- Template updates require manual synchronization

### Neutral

- `.omp/` directory is only relevant when using Oh My Pi harness

## Alternatives Considered

### Manual CI setup

Could have written each workflow from scratch. Rejected because the template provides battle-tested patterns and the adoption cost is low.

### Full template adoption without adaptation

Could have used every template file as-is. Rejected because some files (devcontainer, AI/ML patterns) are irrelevant for a Pike project.
