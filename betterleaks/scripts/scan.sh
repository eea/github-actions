#!/usr/bin/env bash
# ============================================================================
# Betterleaks scan with the EEA base config layered under the repository config.
# Used by betterleaks/action.yml and betterleaks/tests/scan-local.sh, so local
# runs and CI behave the same.
#
# Environment (defaults in brackets):
#   REPO_DIR           repository root, mounted read-only            (required)
#   OUT_DIR            directory for the JSON report                 (required)
#   BETTERLEAKS_IMAGE  pinned image reference                        (required)
#   SCAN_PATH          path to scan, relative to REPO_DIR            [.]
#   MODE               dir | git                                     [dir]
#   LOG_OPTS           git log options for MODE=git                  [-1]
#   CONFIG             repo config, relative to SCAN_PATH            [.gitleaks.toml]
#   BASE_CONFIG        true | false: apply config/eea-base.toml      [true]
#   FAIL_ON_LEAK, UPLOAD_REPORT  true | false, validated only        [true]
#   PULL_ATTEMPTS, PULL_DELAY    image pull retries / seconds        [3, 10]
#
# Writes to $GITHUB_OUTPUT (when set):
#   result       clean | leaks
#   leaks        number of findings
#   exit-code    Betterleaks exit code
#   report-path  absolute path of the JSON report
#   commit       commit checked out in SCAN_PATH (empty if not a git repo)
#
# Exit status: 0 when the scan completed (clean or leaks), 1 on invalid input,
# image pull failure or scanner error. Leaks are reported via outputs, not
# the exit status, so the caller decides whether they fail the job.
#
# Requires: docker, jq, realpath (GNU coreutils), awk.
# ============================================================================
set -euo pipefail

readonly REPORT_NAME="betterleaks-report.json"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)"
readonly BASE_DIR

: "${REPO_DIR:?REPO_DIR is required}"
: "${OUT_DIR:?OUT_DIR is required}"
: "${BETTERLEAKS_IMAGE:?BETTERLEAKS_IMAGE is required}"
SCAN_PATH="${SCAN_PATH:-.}"
MODE="${MODE:-dir}"
LOG_OPTS="${LOG_OPTS:--1}"
CONFIG="${CONFIG:-.gitleaks.toml}"
BASE_CONFIG="${BASE_CONFIG:-true}"
FAIL_ON_LEAK="${FAIL_ON_LEAK:-true}"
UPLOAD_REPORT="${UPLOAD_REPORT:-true}"
PULL_ATTEMPTS="${PULL_ATTEMPTS:-3}"
PULL_DELAY="${PULL_DELAY:-10}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

die() {
  echo "::error::$*" >&2
  exit 1
}

require_bool() {
  [[ "$2" == "true" || "$2" == "false" ]] || die "Input '$1' must be 'true' or 'false', got '$2'."
}

# Resolve $2 (relative to $1) and fail unless it stays inside REPO_DIR.
inside_repo() {
  local resolved
  resolved="$(realpath -m -- "$1/$2")"
  [[ "$resolved" == "$repo_root" || "$resolved" == "$repo_root/"* ]] \
    || die "Path '$2' resolves outside the repository ($resolved)."
  printf '%s\n' "$resolved"
}

validate_inputs() {
  [[ "$MODE" == "dir" || "$MODE" == "git" ]] || die "Input 'mode' must be 'dir' or 'git', got '$MODE'."
  require_bool base-config "$BASE_CONFIG"
  require_bool fail-on-leak "$FAIL_ON_LEAK"
  require_bool upload-report "$UPLOAD_REPORT"
  [[ "$PULL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "PULL_ATTEMPTS must be a positive integer."

  repo_root="$(realpath -e -- "$REPO_DIR")" || die "REPO_DIR '$REPO_DIR' does not exist."
  scan_dir="$(inside_repo "$repo_root" "$SCAN_PATH")"
  [[ -d "$scan_dir" ]] || die "Input 'path' ($SCAN_PATH) is not a directory."
  repo_config="$(inside_repo "$scan_dir" "$CONFIG")"
}

# Write the effective config to $cfg_dir/config.toml; prints which one is used.
prepare_config() {
  if [[ "$BASE_CONFIG" == "true" ]]; then
    if [[ -f "$repo_config" ]]; then
      # Drop the repo file's own [extend] table and extend the EEA base
      # instead (the base extends the Betterleaks defaults).
      awk '/^[[:space:]]*\[extend\][[:space:]]*(#.*)?$/ {skip=1; next}
           skip && /^[[:space:]]*\[/ {skip=0}
           !skip {print}' "$repo_config" > "$cfg_dir/config.toml"
      printf '\n[extend]\npath = "/eea-config/eea-base.toml"\n' >> "$cfg_dir/config.toml"
      echo "Config: EEA base + $CONFIG"
    else
      cp "$BASE_DIR/eea-base.toml" "$cfg_dir/config.toml"
      echo "Config: EEA base ($CONFIG not found)"
    fi
  elif [[ -f "$repo_config" ]]; then
    cp "$repo_config" "$cfg_dir/config.toml"
    echo "Config: $CONFIG"
  else
    echo "Config: Betterleaks defaults"
    return 0
  fi
  return 0
}

# A registry hiccup must not look like a leak: retry, then fail as an error.
pull_image() {
  local attempt
  for (( attempt = 1; attempt <= PULL_ATTEMPTS; attempt++ )); do
    if docker pull --quiet "$BETTERLEAKS_IMAGE" >/dev/null; then
      return 0
    fi
    if (( attempt < PULL_ATTEMPTS )); then
      echo "Image pull failed (attempt $attempt/$PULL_ATTEMPTS), retrying in $(( PULL_DELAY * attempt ))s..."
      sleep $(( PULL_DELAY * attempt ))
    fi
  done
  die "Could not pull $BETTERLEAKS_IMAGE after $PULL_ATTEMPTS attempts. This is an infrastructure problem, not a leak; re-run the job."
}

main() {
  validate_inputs

  mkdir -p "$OUT_DIR"
  local report="$OUT_DIR/$REPORT_NAME"
  rm -f "$report"
  cfg_dir="$(mktemp -d)"
  trap 'rm -rf "$cfg_dir"' EXIT

  prepare_config

  local -a args mounts
  case "$MODE" in
    dir) args=(dir .) ;;
    git) args=(git . --log-opts="$LOG_OPTS") ;;
    *) die "Unsupported mode '$MODE'." ;;
  esac
  args+=(--report-format json --report-path "/out/$REPORT_NAME" --redact --no-color --no-banner)
  # Repository read-only: the scanner only needs to read it.
  mounts=(-v "$repo_root:/repo:ro" -v "$OUT_DIR:/out")
  if [[ -f "$cfg_dir/config.toml" ]]; then
    mounts+=(-v "$cfg_dir:/cfg:ro" -v "$BASE_DIR:/eea-config:ro")
    args+=(--config /cfg/config.toml)
  fi

  local commit=""
  commit="$(git -C "$scan_dir" rev-parse HEAD 2>/dev/null || true)"

  # Run as the calling user: as root, git refuses the mounted repo
  # ("dubious ownership") and the scan silently covers 0 bytes.
  local uid gid workdir
  uid="$(id -u)"
  gid="$(id -g)"
  workdir="/repo/$(realpath --relative-to="$repo_root" "$scan_dir")"

  pull_image

  local rc=0
  docker run --rm --user "$uid:$gid" "${mounts[@]}" -w "$workdir" \
    "$BETTERLEAKS_IMAGE" "${args[@]}" || rc=$?

  local leaks=0
  if [[ -s "$report" ]]; then
    leaks="$(jq 'length' "$report")" || die "Betterleaks wrote an invalid JSON report."
  fi

  local result
  if (( rc == 0 && leaks == 0 )); then
    result="clean"
  elif (( leaks > 0 )); then
    result="leaks"
  else
    die "Betterleaks exited with $rc without reporting findings (scanner error). Check the log above."
  fi

  {
    echo "result=$result"
    echo "leaks=$leaks"
    echo "exit-code=$rc"
    echo "report-path=$report"
    echo "commit=$commit"
  } >> "$OUTPUT_FILE"
  echo "Result: $result ($leaks finding(s))"
}

main "$@"
