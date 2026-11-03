# eea/github-actions

Shared GitHub Actions for EEA repositories. Each action lives in its own directory:

| Action | Usage | Description |
|---|---|---|
| [betterleaks](betterleaks/) | `uses: eea/github-actions/betterleaks@v1` | Secret scan with Betterleaks and the shared EEA rules, report artifact, email to committer |

## Versioning

- Callers use the major tag `@v1`. It is moved forward after each backwards-compatible change.
- Breaking changes to any action's inputs/outputs bump the major tag (`v2`) for the repo.
- Third-party tools (e.g. the Betterleaks image) are pinned by digest inside the action and bumped by PR.

Releasing after a merge to `main`:

```sh
git tag -f v1 && git push -f origin v1
```

## Adding an action

1. Create `<name>/action.yml` (composite action) and `<name>/README.md`.
2. Add a self-test workflow `.github/workflows/test-<name>.yml` filtered on `<name>/**`.
3. Add a row to the table above.
