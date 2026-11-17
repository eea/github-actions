#!/usr/bin/env bash
# ============================================================================
# Tests for scripts/mention-author.sh with a fake `gh` that records the API
# calls it receives and answers from fixtures. No network, no real comments.
#
# Usage: mention-author.test.sh      Exit status: 0 all passed, 1 otherwise.
# ============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

main() {
  install_fake_gh
  write_report

  test_posts_new_comment_mentioning_author
  test_updates_existing_comment_on_rerun
  test_skips_bot_author
  test_skips_unlinked_author
  test_prefixes_scan_path

  (( failures == 0 )) || { echo "$failures test(s) failed"; exit 1; }
  echo "All mention-author tests passed."
}

# The fake gh answers from $work/fixture-* files and logs every call.
install_fake_gh() {
  mkdir -p "$work/bin"
  cat > "$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_DIR/calls.log"
case "$*" in
  *"/commits/"*"/comments --paginate"*) cat "$FAKE_GH_DIR/fixture-comments" ;;
  *"-X POST"*|*"-X PATCH"*)
    body_arg="$(printf '%s\n' "$@" | sed -n 's/^body=@//p')"
    cp "$body_arg" "$FAKE_GH_DIR/posted-body" ;;
  *"/commits/"*) cat "$FAKE_GH_DIR/fixture-login" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$work/bin/gh"
}

write_report() {
  cat > "$work/report.json" <<'JSON'
[{"RuleID":"github-pat","File":"setup.py","StartLine":19,"Description":"GitHub token"},
 {"RuleID":"env-short-secret-assignment","File":"setup.py","StartLine":20,"Description":"env"}]
JSON
}

# Reset fixtures and run the script; $1 = login the commit API returns,
# $2 = comment ids the comment listing returns (one per line, may be empty).
run_with() {
  rm -f "$work/calls.log" "$work/posted-body"
  printf '%s' "$1" > "$work/fixture-login"
  printf '%s' "$2" > "$work/fixture-comments"
  local fake_value="not-a-credential"
  PATH="$work/bin:$PATH" FAKE_GH_DIR="$work" GH_TOKEN="$fake_value" REPO=eea/example COMMIT=abc123 \
    REPORT="$work/report.json" RUN_URL=https://example.test/run SCAN_PATH="${SCAN_PATH_UNDER_TEST:-.}" \
    "$here/scripts/mention-author.sh" > "$work/stdout" 2>&1
}

check() {
  local name="$1"; shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"; sed 's/^/     /' "$work/stdout"
    failures=$(( failures + 1 ))
  fi
}

posted_contains() { grep -qF -- "$1" "$work/posted-body"; }
called() { grep -qF -- "$1" "$work/calls.log"; }
nothing_posted() { [[ ! -e "$work/posted-body" ]]; }

test_posts_new_comment_mentioning_author() {
  run_with "octocat" ""
  check "new comment is created with POST"         called "-X POST repos/eea/example/commits/abc123/comments"
  check "comment mentions the author"              posted_contains "@octocat Betterleaks found **2 potential secret(s)**"
  # shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
  check "comment lists file:line and rule"         posted_contains '- `setup.py:19` (github-pat)'
  check "comment carries the marker"               posted_contains "<!-- betterleaks-mention -->"
  check "comment links the run"                    posted_contains "[Workflow run](https://example.test/run)"
}

test_updates_existing_comment_on_rerun() {
  run_with "octocat" "777"
  check "existing comment is updated with PATCH"   called "-X PATCH repos/eea/example/comments/777"
  check "no second comment is created"             bash -c "! grep -qF -- '-X POST' '$work/calls.log'"
}

test_skips_bot_author() {
  run_with "dependabot[bot]" ""
  check "bot author is not mentioned"              nothing_posted
}

test_skips_unlinked_author() {
  run_with "" ""
  check "unlinked author is not mentioned"         nothing_posted
  check "unlinked author logs a warning"           grep -q '::warning' "$work/stdout"
}

test_prefixes_scan_path() {
  SCAN_PATH_UNDER_TEST=backend run_with "octocat" ""
  # shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
  check "paths are relative to the repository"     posted_contains '- `backend/setup.py:19` (github-pat)'
}

main "$@"
