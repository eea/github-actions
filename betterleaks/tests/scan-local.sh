#!/usr/bin/env bash
# ============================================================================
# Run the same scan as the action, locally: EEA base config + the repository's
# .gitleaks.toml, pinned image from action.yml. Prints the summary CI writes.
#
# Usage: scan-local.sh [repo-dir] [dir|git] [--write-baseline]
#   --write-baseline  scan without a baseline and save every current finding
#                     to <repo>/.betterleaks-baseline.json, so only new
#                     findings fail from now on. Review the file before
#                     committing it: every entry should be a false positive or
#                     a secret that has already been rotated.
# Exit status: 0 clean, 1 leaks found or error.
# ============================================================================
set -euo pipefail

readonly BASELINE_NAME=".betterleaks-baseline.json"

main() {
  parse_arguments "$@"
  read_pinned_image
  run_scan
  show_summary
  save_baseline_if_requested
  exit_with_result
}

parse_arguments() {
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  repo="${1:-.}"
  mode="${2:-dir}"
  write_baseline=false
  [[ "${3:-}" == "--write-baseline" ]] && write_baseline=true
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
}

read_pinned_image() {
  image="$(sed -n 's/^[[:space:]]*BETTERLEAKS_IMAGE:[[:space:]]*//p' "$here/action.yml")"
  [[ -n "$image" ]] || { echo "BETTERLEAKS_IMAGE not found in $here/action.yml" >&2; exit 1; }
}

run_scan() {
  local baseline="$BASELINE_NAME"
  [[ "$write_baseline" == "true" ]] && baseline=""
  REPO_DIR="$repo" OUT_DIR="$tmp/out" MODE="$mode" BETTERLEAKS_IMAGE="$image" \
    BASELINE="$baseline" PULL_DELAY=2 GITHUB_OUTPUT="$tmp/outputs" \
    GITHUB_STEP_SUMMARY="$tmp/summary.md" "$here/scripts/scan.sh"
}

show_summary() {
  echo
  cat "$tmp/summary.md"
}

save_baseline_if_requested() {
  [[ "$write_baseline" == "true" ]] || return 0
  if ! grep -qx 'result=leaks' "$tmp/outputs"; then
    echo "No findings; no baseline written."
    return 0
  fi
  cp "$tmp/out/betterleaks-report.json" "$repo/$BASELINE_NAME"
  echo "Wrote $repo/$BASELINE_NAME. Review it, then commit it."
}

exit_with_result() {
  [[ "$write_baseline" == "true" ]] && exit 0
  grep -qx 'result=clean' "$tmp/outputs"
}

main "$@"
