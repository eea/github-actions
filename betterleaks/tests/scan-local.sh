#!/usr/bin/env bash
# ============================================================================
# Run the same scan as the action, locally: EEA base config + the repository's
# .gitleaks.toml, pinned image from action.yml. Prints the findings.
#
# Usage: scan-local.sh [repo-dir] [dir|git]
# Exit status: 0 clean, 1 leaks found or error.
# ============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${1:-.}"
mode="${2:-dir}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

image="$(sed -n 's/^[[:space:]]*BETTERLEAKS_IMAGE:[[:space:]]*//p' "$here/action.yml")"
[[ -n "$image" ]] || { echo "BETTERLEAKS_IMAGE not found in $here/action.yml" >&2; exit 1; }

REPO_DIR="$repo" OUT_DIR="$tmp/out" MODE="$mode" BETTERLEAKS_IMAGE="$image" \
  PULL_DELAY=2 GITHUB_OUTPUT="$tmp/outputs" "$here/scripts/scan.sh"

if grep -qx 'result=leaks' "$tmp/outputs"; then
  jq -r '.[] | "  \(.RuleID) \(.File):\(.StartLine)"' "$tmp/out/betterleaks-report.json"
  exit 1
fi
