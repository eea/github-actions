# 1. Shared GitHub Actions in one repository

Date: 2026-11-03
Status: Accepted

## Context

82 EEA repositories each carried their own Betterleaks workflow (76 of them on the
third-party `dortort/betterleaks-action`) and a `.gitleaks.toml` whose rules were
almost identical everywhere. Updating the scanner or a rule meant touching every
repository, and the copies had started to drift.

## Decision

- Shared actions live in `eea/github-actions`, one directory per action
  (`uses: eea/github-actions/<name>@v1`), released together under a major tag.
  Breaking input/output changes bump the major tag for the repository.
- Third-party actions are pinned by commit SHA and container images by digest.
  Updates arrive as PRs (Dependabot, `betterleaks-update.yml`) that run the
  self-tests before they are merged.
- Betterleaks rules common to EEA live in `betterleaks/config/eea-base.toml` and
  are applied by the action. Repositories keep only repository-specific
  allowlists in `.gitleaks.toml`, layered on top of the base.

## Alternatives considered

- **One repository per action**: only required for GitHub Marketplace publishing;
  multiplies maintenance.
- **Reusable workflow**: must live directly in `.github/workflows/` (no
  subdirectories) and cannot be grouped per action.
- **Floating image tag (`:latest`)**: lagged behind releases (1.8.1 while 1.9.0
  was out) and changes without review.
- **Keeping full configs per repository**: drift across 82 copies; verified that
  base + trimmed repo configs report identical findings on current repositories.

## Consequences

- One merge and a `v1` tag move update every repository.
- A bad change also reaches every repository at once, hence the self-tests and
  protected `main` / `v*` refs.
- The base config is slightly more permissive than some former copies
  (`JEST_USE_SETUP=ON` accepted, `.yarn/releases/` allowlisted everywhere).
