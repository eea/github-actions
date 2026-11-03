# Changelog

All notable changes to this repository are documented here.
Actions are released together under the major tag (`v1`).

## Unreleased

### Added

- 2026-11-02 — `betterleaks`: composite action that scans for secrets with Betterleaks
  (`dir` or `git` mode), uploads a redacted JSON report, emails the committer and fails the job.
  Replaces the per-repository Betterleaks workflows.
- 2026-11-02 — `betterleaks`: shared EEA base config (`betterleaks/config/eea-base.toml`), applied
  automatically. Repository `.gitleaks.toml` files only need their own allowlists.
- 2026-11-02 — `betterleaks`: Betterleaks image pinned by tag and digest (v1.9.0), and a weekly
  update check that opens a tested bump PR.
- 2026-11-02 — Self-test workflow with a runtime-generated fake leak.
