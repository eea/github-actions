# Changelog

All notable changes to this repository are documented here.
Actions are released together under the major tag (`v1`).

## Unreleased

### Added (comparison with other Betterleaks and Gitleaks actions)

- 2026-11-03 — `betterleaks`: results on the check itself — one error annotation per finding at its
  file and line (also inline in pull request diffs), a notice for clean scans, and a job summary
  with all findings, scan details and config.
- 2026-11-03 — `betterleaks`: `baseline` input (default `.betterleaks-baseline.json`, used when
  present) so repositories with existing findings fail only on new ones;
  `tests/scan-local.sh <repo> dir --write-baseline` creates it.
- 2026-11-03 — `betterleaks`: `timeout-minutes` input (default 15). Enforced outside the scanner:
  Betterleaks' own `--timeout` stops early and still reports "no leaks found".
- 2026-11-03 — `betterleaks`: a scan that did not read the repository fails as an error instead of
  passing as clean (Betterleaks "partial scan" warning, or 0 bytes scanned in `dir` mode).
- 2026-11-03 — `betterleaks`: live validation explicitly disabled (`--validation=false`), so found
  secrets are never sent to provider APIs even if a future release changes the default.

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

- 2026-11-03 — `betterleaks`: `fallback-email` input, and lookup of the public email on the commit
  author's GitHub profile when the commit only has no-reply addresses.

- 2026-11-03 — `betterleaks` README: example workflow skips the duplicate `pull_request` scan for
  branches of the same repository (`push` covers them); `pull_request` only runs for forks.

### Changed (review of the action's shell code)

- 2026-11-03 — `betterleaks`: scan logic moved to `scripts/scan.sh`, shared by the action and
  `tests/scan-local.sh` (no more duplicated config merge); shellcheck-clean, `set -euo pipefail`.
- 2026-11-03 — `betterleaks`: the repository is mounted read-only into the scanner; the report is
  written under `RUNNER_TEMP` instead of the checkout.
- 2026-11-03 — `betterleaks`: the image pull is retried 3 times; pull failures and scanner errors fail
  the step as errors and no longer email the committer as if a leak was found.
- 2026-11-03 — `betterleaks`: the email names the scanned commit and the PR head branch (was the merge
  commit / `N/merge` on `pull_request`). New outputs `result` and `commit`.
- 2026-11-03 — `betterleaks`: inputs are validated (`mode`, boolean inputs, `path` and `config` must
  stay inside the workspace); an invalid `fallback-email` is reported.

### Fixed
- 2026-11-03 — `betterleaks` base config: `docker run -v "$PWD:/path"` was reported by
  `secret-literal-assignment` (`PWD` read as a password name). Allowlisted when the match is
  `PWD:/…` only; `pwd=…`, `DB_PWD: …` and similar are still reported.
- 2026-11-03 — `betterleaks`: the committer email was sent to `noreply@github.com` for commits made in
  the GitHub web UI. All no-reply addresses are now skipped and the chosen recipient is logged.

### Changed

- 2026-11-03 — Bumped `actions/checkout` to v7.0.1, `actions/upload-artifact` to v7.0.2 and
  `dawidd6/action-send-mail` to v24 (no input changes; send-mail ignores `HTTP_PROXY` since v20).
