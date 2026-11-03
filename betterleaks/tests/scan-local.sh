#!/usr/bin/env bash
# Run the same scan as the action locally: EEA base config + the repo's .gitleaks.toml.
# Usage: scan-local.sh [repo-dir] [dir|git] [extra betterleaks args...]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "${1:-.}" && pwd)"; mode="${2:-dir}"; shift $(( $# > 2 ? 2 : $# ))
image="$(grep -oP 'BETTERLEAKS_IMAGE: \K\S+' "$here/action.yml")"
cfg="$(mktemp -d)"; trap 'rm -rf "$cfg"' EXIT
if [[ -f "$repo/.gitleaks.toml" ]]; then
  awk '/^[[:space:]]*\[extend\][[:space:]]*(#.*)?$/ {skip=1; next}
       skip && /^[[:space:]]*\[/ {skip=0}
       !skip {print}' "$repo/.gitleaks.toml" > "$cfg/config.toml"
  printf '\n[extend]\npath = "/eea-config/eea-base.toml"\n' >> "$cfg/config.toml"
else
  cp "$here/config/eea-base.toml" "$cfg/config.toml"
fi
args=(dir .); [[ "$mode" == git ]] && args=(git . --log-opts=-1)
docker run --rm --user "$(id -u):$(id -g)" -v "$repo:/repo:ro" \
  -v "$here/config:/eea-config:ro" -v "$cfg:/cfg:ro" -w /repo "$image" \
  "${args[@]}" --config /cfg/config.toml --redact --no-banner "$@"
