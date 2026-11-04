# betterleaks

Scans for secrets with [Betterleaks](https://github.com/betterleaks/betterleaks) (Gitleaks-compatible config)
using the shared EEA rules plus the repository's own config, uploads a redacted JSON report,
emails the committer when leaks are found and fails the job.

The Betterleaks image is pinned by tag and digest in `action.yml`. A weekly workflow
(`.github/workflows/betterleaks-update.yml`) opens a PR when a new release is out, after verifying
the new image still detects a fake leak. Callers on `@v1` get the update once `v1` is moved.

## Usage

```yaml
# .github/workflows/betterleaks.yml
name: Betterleaks

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  scan:
    name: Scan for secrets
    # push covers branches in this repo; pull_request is only needed for forks
    if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name != github.repository
    runs-on: ubuntu-latest
    timeout-minutes: 20 # outer guard; the scan itself stops after timeout-minutes (15)
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
          fetch-depth: 1 # use 2 with mode: git
          ref: ${{ github.event.pull_request.head.sha || github.sha }}

      - uses: eea/github-actions/betterleaks@v1
        with:
          # mode: git    # scan only the latest commit instead of the whole tree
          smtp-url: ${{ secrets.SMTP_URL }}
          smtp-port: ${{ secrets.SMTP_PORT || '25' }}
          smtp-email: ${{ secrets.SMTP_EMAIL }}
          smtp-password: ${{ secrets.SMTP_PASSWORD }}
          fallback-email: ${{ vars.BETTERLEAKS_FALLBACK_EMAIL }}
          # Optional, see "Mentioning the author": needs `contents: write` on the job
          # mention-author: ${{ vars.BETTERLEAKS_MENTION_AUTHOR == 'true' }}
```

## Configuration

Two layers are applied, on top of the Betterleaks default rules:

1. **EEA base config**: [`config/eea-base.toml`](config/eea-base.toml), shipped with the action.
   Shared rules (secret-like literal assignments, `PASS`/`TOKEN`/`SECRET` env assignments,
   standalone `sk-` tokens, `.env` content, forbidden secret files such as `*.pem`, `.npmrc`)
   and allowlists common to all EEA repos. Change it here, once, for every repository.
2. **Repository config**: `.gitleaks.toml` (input `config`), optional. Only what is specific to the
   repository: path allowlists, chart placeholder values, etc. A repo rule with the same `id` as a
   base rule overrides it.

Minimal repository config:

```toml
title = "my-repo Betterleaks config"

[extend]
useDefault = true

[[allowlists]]
description = "Allow local development defaults"
paths = ['''(^|/)develop/etc/.*\.conf$''']
```

The action replaces the repo file's `[extend]` table with a reference to the base config, so the same
file still works on its own for local runs (`betterleaks dir . -c .gitleaks.toml`: defaults + repo rules).
To run the same scan locally (same script, pinned image and config layering as CI):

```sh
betterleaks/tests/scan-local.sh /path/to/repo        # dir mode
betterleaks/tests/scan-local.sh /path/to/repo git    # latest commit only
```

How to deal with what the scan reports is described in [Handling findings](#handling-findings).

## Inputs

| Input | Default | Description |
|---|---|---|
| `mode` | `dir` | `dir` scans the whole checkout; `git` scans the commits selected by `log-opts` |
| `log-opts` | `-1` | `git log` options for `git` mode; default is only the latest commit |
| `path` | `.` | Repo path to scan, relative to the workspace |
| `config` | `.gitleaks.toml` | Repository config relative to `path` (optional) |
| `base-config` | `true` | Apply the EEA base config; `false` uses only the repo config / defaults |
| `baseline` | `.betterleaks-baseline.json` | Known findings to ignore, relative to `path`; used when the file exists. Empty disables |
| `timeout-minutes` | `15` | Scan time limit; a scan that does not finish fails as an error |
| `fail-on-leak` | `true` | Fail the job when leaks are found |
| `upload-report` | `true` | Upload the JSON report as an artifact |
| `artifact-name` | `betterleaks-report` | Artifact name |
| `smtp-url`, `smtp-port`, `smtp-email`, `smtp-password` | empty / `25` | Email notification; skipped when `smtp-url` or `smtp-email` is empty |
| `fallback-email` | empty | Recipient when the committer has no deliverable address (see below) |
| `mention-author` | `false` | On leaks, @mention the commit author in a commit comment (see below) |
| `comment-token` | `github.token` | Token for that comment; needs `contents: write` |

Inputs are validated: `mode` must be `dir` or `git`, the `true`/`false` inputs must be exactly that,
`timeout-minutes` must be a positive integer, and `path` / `config` / `baseline` must stay inside the
workspace.

## Outputs

| Output | Description |
|---|---|
| `result` | `clean` or `leaks` |
| `leaks` | Number of findings |
| `exit-code` | Betterleaks exit code |
| `report-path` | JSON report, under `RUNNER_TEMP` (never written into the checkout) |
| `commit` | Commit that was scanned; also used in the email |

## What shows on the check

The job is the check on the commit (green tick / red cross). Click it to see:

- **Leaks**: one error annotation per finding at its file and line (the first 10; GitHub's limit per
  step). In pull requests the same annotations appear inline in "Files changed".
- **Clean**: a notice, e.g. "No secrets found (64.39 KB scanned, dir scan of `beb8f2694eee`, config:
  EEA base + .gitleaks.toml)".
- **Job summary** on the run page: scan, commit, bytes scanned, config, baseline and a table of all
  findings (rule, file, line). Values are always redacted.

## Handling findings

Decide in this order. Each case has one tool; do not use a later one for an earlier case.

| Finding | Do this | Why this tool |
|---|---|---|
| **A real secret** | Remove it **and rotate it**. Removing is not enough: it is in the git history and was public on public repositories. | Nothing else makes it safe |
| **A false positive on one line**, in a file that allows comments (YAML, Python, shell, Jenkinsfile, Dockerfile, docker-compose) | Add a `betterleaks:allow` comment on that line | Stays with the line when the file changes; visible in review |
| **A false-positive pattern**: it recurs, or the file cannot take comments (JSON, lock files, generated, vendored or minified files, config formats such as ZConfig) | Add an allowlist to the repository `.gitleaks.toml`, as narrow as possible (`paths` + `regexes` with `condition = "AND"`) | Matches by pattern, so it survives edits, and carries a description |
| **The same pattern in many repositories** | Propose it for the EEA base config ([`config/eea-base.toml`](config/eea-base.toml)) in this repository | One change for every repository |
| **A backlog of existing findings** when first enabling the scan in a repository | A [baseline](#baseline-temporary-for-adoption-only), temporarily, while the backlog is fixed with the rows above | Only tool that ignores existing findings without touching them |

Inline comment examples:

```yaml
POSTGRES_PASSWORD: postgres # betterleaks:allow (local development only)
```

```groovy
withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_AUTH_TOKEN')]) { //betterleaks:allow
```

Repository allowlist example (the value **and** the file must match, so a real secret added to the same
file is still reported):

```toml
[[allowlists]]
description = "Local development RelStorage password defaults"
condition = "AND"
paths = ['''(?i)(^|/)develop/etc/relstorage\.conf$''']
regexTarget = "match"
regexes = ['''password='zope''']  # betterleaks:allow (allowlist pattern, not a secret)
```

That particular one is already in the EEA base config, like the other exceptions shared by many
repositories. Anyone can add a `betterleaks:allow` comment, so reviewers should treat one like any other
change to security checks.

### Baseline: temporary, for adoption only

In `dir` mode an existing finding fails every run until it is handled. When enabling the scan in a
repository with a backlog, record the current findings once so that only new ones fail:

```sh
betterleaks/tests/scan-local.sh /path/to/repo dir --write-baseline
# review /path/to/repo/.betterleaks-baseline.json, then commit it
```

- Review every entry before committing: a real secret in the list must still be removed and rotated.
- Entries match on file, rule **and line**: an edit above a known finding makes it "new" again, and an
  entry silences whatever is on that line, including a different secret added there later. That is
  why exceptions belong in comments or allowlists, not in the baseline.
- Work the backlog down with the table above and delete the file when it is empty. The job summary
  shows how many known findings the baseline still ignores.

## Errors vs leaks

Leaks set `result=leaks`, email the committer and fail the job in the last step. Problems that are not
leaks fail the scan step itself, without an email and without a result:

- invalid inputs
- the Betterleaks image not being pullable (retried 3 times first); re-run the job
- the scan not finishing within `timeout-minutes` (Betterleaks' own `--timeout` is not used: it stops
  early and still reports "no leaks found")
- a scan that did not read the repository: Betterleaks' "partial scan" warning, or 0 bytes scanned in
  `dir` mode (in `git` mode a merge commit legitimately has nothing to scan)
- other scanner errors

Live validation of findings against provider APIs is explicitly off (`--validation=false`), so found
secrets are never sent anywhere.

The scan logic lives in [`scripts/scan.sh`](scripts/scan.sh); the repository is mounted read-only into
the scanner container.

## Who gets the email

The first deliverable address of: the commit's committer, the commit's author, the public email on
the author's GitHub profile, then `fallback-email`. No-reply addresses (`noreply@github.com`,
`<id>+<login>@users.noreply.github.com`, `no-reply@...`) are never used. Commits made in the GitHub web
UI, or by users who keep their email private, only carry no-reply addresses, so set `fallback-email`
(for example from an organization variable `BETTERLEAKS_FALLBACK_EMAIL`). Without any address, the run
logs a warning and still fails.

## Mentioning the author

With `mention-author: true`, a scan with findings also writes a commit comment:

> @octocat Betterleaks found **2 potential secret(s)** in the files at this commit:
> - `setup.py:19` (secret-literal-assignment)
> - `setup.py:20` (env-short-secret-assignment)

GitHub then notifies the author through their own notification settings, at their real address, which
works even when the commit only carries no-reply emails. Re-runs update the same comment instead of
adding new ones. Bots and authors whose commit email is not linked to a GitHub account are skipped.

- **Permissions**: creating a commit comment needs `contents: write`. Grant it on the scan job, or pass
  a `comment-token` from a GitHub App installed only where needed. Do not make an app private key an
  organization-wide secret for this: any repository's workflow could then use the app's permissions.
- **Toggle**: pass `${{ vars.BETTERLEAKS_MENTION_AUTHOR == 'true' }}` and set the variable on the
  repository or the organization.
- **Never changes the result**: if the comment cannot be written (missing permission, fork pull request
  with a read-only token), the step logs a warning and the scan result stands.
- Comments are public on public repositories. They contain only what the public log already shows:
  rule, file and line, values redacted.

## Triggers

`push` scans every branch of the repository, including direct pushes without a PR. A PR from a
branch of the same repository would be scanned a second time by `pull_request`, so the job skips
those; the PR still shows the result of the `push` run on the same commit, and a job skipped by `if:`
counts as successful for required checks. `pull_request` is kept for PRs from forks, which never
trigger `push` here (they get no secrets, so no email, but the check still fails).

## Notes

- `mode: git` with `log-opts: -1` only scans the latest commit; secrets in earlier commits of a
  multi-commit push are not caught. Use e.g. `log-opts: ${{ github.event.before }}..${{ github.sha }}`
  with `fetch-depth: 0` to scan the whole push.
- `mode: dir` scans the files as checked out, so an existing leak keeps failing until it is removed
  or allowlisted.
