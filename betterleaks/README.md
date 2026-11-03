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
    runs-on: ubuntu-latest
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
To run locally with the EEA rules too, use [`tests/scan-local.sh`](tests/scan-local.sh).

Single findings can still be silenced inline with a `betterleaks:allow` (or `gitleaks:allow`) comment.

## Inputs

| Input | Default | Description |
|---|---|---|
| `mode` | `dir` | `dir` scans the whole checkout; `git` scans the commits selected by `log-opts` |
| `log-opts` | `-1` | `git log` options for `git` mode; default is only the latest commit |
| `path` | `.` | Repo path to scan, relative to the workspace |
| `config` | `.gitleaks.toml` | Repository config relative to `path` (optional) |
| `base-config` | `true` | Apply the EEA base config; `false` uses only the repo config / defaults |
| `fail-on-leak` | `true` | Fail the job when leaks are found |
| `upload-report` | `true` | Upload the JSON report as an artifact |
| `artifact-name` | `betterleaks-report` | Artifact name |
| `smtp-url`, `smtp-port`, `smtp-email`, `smtp-password` | empty / `25` | Email notification; skipped when `smtp-url` or `smtp-email` is empty |

## Outputs

`leaks` (count), `exit-code`, `report-path`.

## Notes

- `mode: git` with `log-opts: -1` only scans the latest commit; secrets in earlier commits of a
  multi-commit push are not caught. Use e.g. `log-opts: ${{ github.event.before }}..${{ github.sha }}`
  with `fetch-depth: 0` to scan the whole push.
- `mode: dir` scans the files as checked out, so an existing leak keeps failing until it is removed
  or allowlisted.
- A non-zero exit without findings is a scan error and also fails the job (and emails "No JSON report").
