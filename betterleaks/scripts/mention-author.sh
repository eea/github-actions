#!/usr/bin/env bash
# ============================================================================
# Mention the commit author in a commit comment when Betterleaks found leaks,
# so GitHub notifies them at their real address (we never see it).
# One comment per commit: a re-run updates it instead of adding another.
#
# Environment:
#   GH_TOKEN     token allowed to write commit comments (contents: write)  (required)
#   REPO         owner/name                                              (required)
#   COMMIT       scanned commit SHA                                      (required)
#   REPORT       Betterleaks JSON report                                 (required)
#   RUN_URL      link to the workflow run                                (required)
#   SCAN_PATH    scanned path, prefixed to report paths                  [.]
#   HANDLING_URL link to the "Handling findings" guide                   [README]
#   LIST_LIMIT   findings listed in the comment                          [20]
#
# Exit status: 0 when the comment was written or deliberately skipped,
# 1 on API errors. The action runs this with continue-on-error, so a failed
# comment never changes the scan result.
#
# Requires: gh, jq.
# ============================================================================
set -euo pipefail

readonly MARKER="<!-- betterleaks-mention -->"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${COMMIT:?COMMIT is required}"
: "${REPORT:?REPORT is required}"
: "${RUN_URL:?RUN_URL is required}"
SCAN_PATH="${SCAN_PATH:-.}"
HANDLING_URL="${HANDLING_URL:-https://github.com/eea/github-actions/tree/main/betterleaks#handling-findings}"
LIST_LIMIT="${LIST_LIMIT:-20}"

main() {
  find_author_login
  author_is_mentionable || exit 0
  compose_comment
  post_or_update_comment
}

find_author_login() {
  login="$(gh api "repos/$REPO/commits/$COMMIT" --jq '.author.login // empty')"
}

# No login: the commit email is not linked to a GitHub account.
# Bots: nobody reads their notifications.
author_is_mentionable() {
  if [[ -z "$login" ]]; then
    echo "::warning title=Betterleaks::Commit author is not linked to a GitHub account; nobody mentioned."
    return 1
  fi
  if [[ "$login" == *"[bot]" ]]; then
    echo "Commit author $login is a bot; nobody mentioned."
    return 1
  fi
}

compose_comment() {
  local count prefix
  count="$(jq 'length' "$REPORT")"
  prefix=""
  [[ "$SCAN_PATH" != "." ]] && prefix="${SCAN_PATH%/}/"
  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' EXIT
  {
    echo "$MARKER"
    echo "@$login Betterleaks found **$count potential secret(s)** in the files at this commit:"
    echo
    jq -r --arg prefix "$prefix" --argjson limit "$LIST_LIMIT" \
      '.[:$limit][] | "- `\($prefix)\(.File):\(.StartLine)` (\(.RuleID))"' "$REPORT"
    (( count > LIST_LIMIT )) && echo "- ... and $(( count - LIST_LIMIT )) more"
    echo
    echo "Values are redacted. If one is a real secret, remove it and **rotate it**: it is in the git"
    echo "history. If not, see [Handling findings]($HANDLING_URL)."
    echo
    echo "[Workflow run]($RUN_URL)"
  } > "$body_file"
}

# Look for our earlier comment on this commit (re-runs) and update it.
post_or_update_comment() {
  local existing
  existing="$(gh api "repos/$REPO/commits/$COMMIT/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" | head -n 1)"
  if [[ -n "$existing" ]]; then
    gh api -X PATCH "repos/$REPO/comments/$existing" -F "body=@$body_file" --silent
    echo "Updated the commit comment mentioning @$login."
    return 0
  fi
  gh api -X POST "repos/$REPO/commits/$COMMIT/comments" -F "body=@$body_file" --silent
  echo "Mentioned @$login in a commit comment."
}

main "$@"
