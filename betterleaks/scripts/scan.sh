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
#   BASELINE           known findings to ignore, relative to SCAN_PATH;
#                      empty disables                               [.betterleaks-baseline.json]
#   TIMEOUT_MINUTES    scan time limit                               [15]
#   FAIL_ON_LEAK, UPLOAD_REPORT  true | false, validated only        [true]
#   MENTION_AUTHOR               true | false, validated only        [false]
#   PULL_ATTEMPTS, PULL_DELAY    image pull retries / seconds        [3, 10]
#   ANNOTATION_LIMIT   findings annotated on the check               [10]
#
# Writes to $GITHUB_OUTPUT (when set):
#   result       clean | leaks
#   leaks        number of new findings (baseline excluded)
#   exit-code    Betterleaks exit code
#   report-path  absolute path of the JSON report
#   commit       commit checked out in SCAN_PATH (empty if not a git repo)
# Also writes a Markdown summary to $GITHUB_STEP_SUMMARY and GitHub
# annotations (one per finding, or a notice when clean) to stdout.
#
# Exit status: 0 when the scan completed (clean or leaks), 1 on invalid input,
# image pull failure, timeout or scanner error. Leaks are reported via outputs,
# not the exit status, so the caller decides whether they fail the job.
#
# Requires: docker, jq, timeout and realpath (GNU coreutils), awk.
# ============================================================================
set -euo pipefail

readonly REPORT_NAME="betterleaks-report.json"
readonly HANDLING_FINDINGS_URL="https://github.com/eea/github-actions/tree/main/betterleaks#handling-findings"
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
BASELINE="${BASELINE-.betterleaks-baseline.json}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-15}"
FAIL_ON_LEAK="${FAIL_ON_LEAK:-true}"
UPLOAD_REPORT="${UPLOAD_REPORT:-true}"
MENTION_AUTHOR="${MENTION_AUTHOR:-false}"
PULL_ATTEMPTS="${PULL_ATTEMPTS:-3}"
PULL_DELAY="${PULL_DELAY:-10}"
ANNOTATION_LIMIT="${ANNOTATION_LIMIT:-10}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"

main() {
  validate_inputs
  prepare_work_dirs
  prepare_config
  prepare_baseline
  build_scanner_command

  pull_image
  run_scanner
  require_complete_scan
  classify_result

  annotate_check
  write_summary
  write_outputs
}

# --- helpers ------------------------------------------------------------------

die() {
  echo "::error title=Betterleaks::$*" >&2
  exit 1
}

require_bool() {
  [[ "$2" == "true" || "$2" == "false" ]] || die "Input '$1' must be 'true' or 'false', got '$2'."
}

require_positive_int() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "Input '$1' must be a positive integer, got '$2'."
}

# Resolve $2 (relative to $1) and fail unless it stays inside the repository.
inside_repo() {
  local resolved
  resolved="$(realpath -m -- "$1/$2")"
  [[ "$resolved" == "$repo_root" || "$resolved" == "$repo_root/"* ]] \
    || die "Path '$2' resolves outside the repository ($resolved)."
  printf '%s\n' "$resolved"
}

# Path of $1 relative to the repository root, as the container sees it.
container_path() {
  local relative
  relative="$(realpath --relative-to="$repo_root" "$1")"
  printf '/repo/%s\n' "$relative"
}

# --- steps --------------------------------------------------------------------

validate_inputs() {
  [[ "$MODE" == "dir" || "$MODE" == "git" ]] || die "Input 'mode' must be 'dir' or 'git', got '$MODE'."
  require_bool base-config "$BASE_CONFIG"
  require_bool fail-on-leak "$FAIL_ON_LEAK"
  require_bool upload-report "$UPLOAD_REPORT"
  require_bool mention-author "$MENTION_AUTHOR"
  require_positive_int timeout-minutes "$TIMEOUT_MINUTES"
  require_positive_int PULL_ATTEMPTS "$PULL_ATTEMPTS"
  require_positive_int ANNOTATION_LIMIT "$ANNOTATION_LIMIT"

  repo_root="$(realpath -e -- "$REPO_DIR")" || die "REPO_DIR '$REPO_DIR' does not exist."
  scan_dir="$(inside_repo "$repo_root" "$SCAN_PATH")"
  [[ -d "$scan_dir" ]] || die "Input 'path' ($SCAN_PATH) is not a directory."
  repo_config="$(inside_repo "$scan_dir" "$CONFIG")"
  baseline_file=""
  if [[ -n "$BASELINE" ]]; then
    baseline_file="$(inside_repo "$scan_dir" "$BASELINE")"
  fi
  commit="$(git -C "$scan_dir" rev-parse HEAD 2>/dev/null || true)"
}

prepare_work_dirs() {
  mkdir -p "$OUT_DIR"
  report="$OUT_DIR/$REPORT_NAME"
  scanner_log="$OUT_DIR/betterleaks.log"
  rm -f "$report" "$scanner_log"
  cfg_dir="$(mktemp -d)"
  trap 'rm -rf "$cfg_dir"' EXIT
}

# Write the effective config to $cfg_dir/config.toml and set config_label.
prepare_config() {
  config_label="Betterleaks defaults"
  if [[ "$BASE_CONFIG" == "false" ]]; then
    use_repo_config_only
  elif [[ -f "$repo_config" ]]; then
    layer_repo_config_on_base
  else
    cp "$BASE_DIR/eea-base.toml" "$cfg_dir/config.toml"
    config_label="EEA base ($CONFIG not found)"
  fi
  echo "Config: $config_label"
}

use_repo_config_only() {
  [[ -f "$repo_config" ]] || return 0
  cp "$repo_config" "$cfg_dir/config.toml"
  config_label="$CONFIG"
}

# Drop the repo file's own [extend] table and extend the EEA base instead
# (the base extends the Betterleaks defaults).
layer_repo_config_on_base() {
  awk '/^[[:space:]]*\[extend\][[:space:]]*(#.*)?$/ {skip=1; next}
       skip && /^[[:space:]]*\[/ {skip=0}
       !skip {print}' "$repo_config" > "$cfg_dir/config.toml"
  printf '\n[extend]\npath = "/eea-config/eea-base.toml"\n' >> "$cfg_dir/config.toml"
  config_label="EEA base + $CONFIG"
}

prepare_baseline() {
  baseline_label="none"
  [[ -n "$baseline_file" && -f "$baseline_file" ]] || return 0
  local known
  known="$(jq 'length' "$baseline_file" 2>/dev/null)" \
    || die "Baseline $BASELINE is not a Betterleaks JSON report."
  baseline_label="$BASELINE ($known known finding(s) ignored)"
  echo "Baseline: $baseline_label"
}

build_scanner_command() {
  case "$MODE" in
    dir) scanner_args=(dir .) ;;
    git) scanner_args=(git . --log-opts="$LOG_OPTS") ;;
    *) die "Unsupported mode '$MODE'." ;;
  esac
  # Live validation would send found secrets to provider APIs; keep it off
  # explicitly in case a future release changes the default.
  scanner_args+=(--report-format json --report-path "/out/$REPORT_NAME"
                 --redact --validation=false --no-color --no-banner)
  # Repository read-only: the scanner only needs to read it.
  docker_args=(-v "$repo_root:/repo:ro" -v "$OUT_DIR:/out" -w "$(container_path "$scan_dir")")
  if [[ -f "$cfg_dir/config.toml" ]]; then
    docker_args+=(-v "$cfg_dir:/cfg:ro" -v "$BASE_DIR:/eea-config:ro")
    scanner_args+=(--config /cfg/config.toml)
  fi
  if [[ "$baseline_label" != "none" ]]; then
    scanner_args+=(--baseline-path "$(container_path "$baseline_file")")
  fi
}

# A registry hiccup must not look like a leak: retry, then fail as an error.
pull_image() {
  local attempt
  for (( attempt = 1; attempt <= PULL_ATTEMPTS; attempt++ )); do
    docker pull --quiet "$BETTERLEAKS_IMAGE" >/dev/null && return 0
    (( attempt < PULL_ATTEMPTS )) || break
    echo "Image pull failed (attempt $attempt/$PULL_ATTEMPTS), retrying in $(( PULL_DELAY * attempt ))s..."
    sleep $(( PULL_DELAY * attempt ))
  done
  die "Could not pull $BETTERLEAKS_IMAGE after $PULL_ATTEMPTS attempts. This is an infrastructure problem, not a leak; re-run the job."
}

# The time limit is enforced here, not with Betterleaks' --timeout: that flag
# stops the scan early and still reports "no leaks found" with exit code 0.
run_scanner() {
  local uid gid container
  uid="$(id -u)"
  gid="$(id -g)"
  container="betterleaks-$$-${RANDOM}"
  scanner_rc=0
  # As root, git refuses the mounted repo ("dubious ownership"): run as the caller.
  timeout "$(( TIMEOUT_MINUTES * 60 ))" \
    docker run --rm --name "$container" --user "$uid:$gid" "${docker_args[@]}" \
      "$BETTERLEAKS_IMAGE" "${scanner_args[@]}" 2>&1 | tee "$scanner_log" || scanner_rc=$?
  (( scanner_rc != 124 )) && return 0
  docker kill "$container" >/dev/null 2>&1 || true
  die "Scan did not finish within $TIMEOUT_MINUTES minute(s); no result. Raise timeout-minutes or exclude large generated files."
}

# Betterleaks reports problems reading the repository only as log lines and
# then says "no leaks found". Treat those as errors, not as a clean scan.
require_complete_scan() {
  if grep -q 'partial scan' "$scanner_log"; then
    die "Betterleaks could only partially scan the repository (see the log above); no result."
  fi
  scanned="$(sed -n 's/.*scanned ~[0-9]* bytes (\([^)]*\)).*/\1/p' "$scanner_log" | tail -n 1)"
  # A merge or deletion-only commit legitimately has nothing to scan in git mode.
  if [[ "$MODE" == "dir" && "$scanned" == "0" ]]; then
    die "Betterleaks scanned 0 bytes in '$SCAN_PATH'; the files were not read. No result."
  fi
  [[ "$scanned" == "0" || -z "$scanned" ]] && scanned="0 bytes"
  return 0
}

classify_result() {
  leaks=0
  if [[ -s "$report" ]]; then
    leaks="$(jq 'length' "$report")" || die "Betterleaks wrote an invalid JSON report."
  fi
  if (( scanner_rc == 0 && leaks == 0 )); then
    result="clean"
  elif (( leaks > 0 )); then
    result="leaks"
  else
    die "Betterleaks exited with $scanner_rc without reporting findings (scanner error). Check the log above."
  fi
  echo "Result: $result ($leaks finding(s))"
}

# Annotations show on the check (the green tick / red cross on the commit)
# and inline in pull request diffs. GitHub shows at most 10 errors per step.
annotate_check() {
  if [[ "$result" == "clean" ]]; then
    echo "::notice title=Betterleaks::No secrets found (${scanned:-0} scanned, $MODE scan of ${commit:0:12}, config: $config_label)."
    return 0
  fi
  local prefix
  prefix="$(realpath --relative-to="$repo_root" "$scan_dir")/"
  [[ "$prefix" == "./" ]] && prefix=""
  jq -r --arg prefix "$prefix" --argjson limit "$ANNOTATION_LIMIT" '
    def prop: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A")
                       | gsub(":"; "%3A") | gsub(","; "%2C");
    def msg: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
    .[:$limit][]
    | "::error file=\(($prefix + .File) | prop),line=\(.StartLine),endLine=\(.EndLine),"
      + "title=\(("Betterleaks: " + .RuleID) | prop)::"
      + ("Potential secret: \(.Description). Value redacted; remove it, rotate it, "
         + "or allowlist it if it is not a secret." | msg)
  ' "$report"
  if (( leaks > ANNOTATION_LIMIT )); then
    echo "::error title=Betterleaks::$leaks potential secrets; only the first $ANNOTATION_LIMIT are annotated. See the job summary for all of them."
  fi
}

write_summary() {
  {
    if [[ "$result" == "clean" ]]; then
      echo "## Betterleaks: no secrets found"
    else
      echo "## Betterleaks: $leaks potential secret(s) found"
    fi
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Scan | \`$MODE\` of \`$SCAN_PATH\` |"
    echo "| Commit | \`${commit:-n/a}\` |"
    echo "| Scanned | ${scanned:-0} |"
    echo "| Config | $config_label |"
    echo "| Baseline | $baseline_label |"
    [[ "$result" == "clean" ]] && return 0
    echo
    echo "| Rule | File | Line |"
    echo "|---|---|---|"
    jq -r '.[:100][] | "| `\(.RuleID)` | `\(.File)` | \(.StartLine) |"' "$report"
    (( leaks > 100 )) && echo "| ... | $(( leaks - 100 )) more in the report artifact | |"
    echo
    echo "Values are redacted. For each finding: remove the secret and **rotate it** (it is in the git"
    echo "history), or, if it is not a secret, add a \`betterleaks:allow\` comment or an allowlist in"
    echo "\`$CONFIG\`. See [Handling findings]($HANDLING_FINDINGS_URL)."
  } >> "$SUMMARY_FILE"
}

write_outputs() {
  {
    echo "result=$result"
    echo "leaks=$leaks"
    echo "exit-code=$scanner_rc"
    echo "report-path=$report"
    echo "commit=$commit"
  } >> "$OUTPUT_FILE"
}

main "$@"
