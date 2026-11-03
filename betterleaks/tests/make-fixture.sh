#!/usr/bin/env bash
# Create a git repo whose latest commit contains a fake GitHub token.
# The token is generated at runtime so this repo never contains anything
# that looks like a secret.
set -euo pipefail
dir="${1:?usage: make-fixture.sh <dir>}"
mkdir -p "$dir" && cd "$dir"
git init -q
git config user.email test@example.com
git config user.name test
echo clean > a.txt
git add . && git commit -qm init
token="ghp_$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)"
printf 'github:\n  token: %s\n' "$token" > values.yaml
git add values.yaml && git commit -qm "add fake token"
