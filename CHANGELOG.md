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
- 2026-11-03 — Self-test `notify` job: verifies the report artifact upload, the committer
  email (via a Mailpit SMTP service container) and the failing final step, so bumps of
  `upload-artifact` and `action-send-mail` are actually exercised.

### Changed

- 2026-11-03 — Bumped `actions/checkout` to v7.0.1, `actions/upload-artifact` to v7.0.2 and
  `dawidd6/action-send-mail` to v24 (no input changes; send-mail ignores `HTTP_PROXY` since v20).
