#!/usr/bin/env bash
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)/skills/nixos-agent-test-vm"

install_to() {
  rm -rf "$1/nixos-agent-test-vm"
  mkdir -p "$1"
  cp -rL --no-preserve=mode,ownership "$src" "$1/"
  chmod +x "$1/nixos-agent-test-vm/check.sh"
  echo "installed $1/nixos-agent-test-vm"
}

targets=()
[ -d .claude ] && targets+=(.claude/skills)
[ -d .agents ] && targets+=(.agents/skills)
[ ${#targets[@]} -eq 0 ] && targets=(.claude/skills)

for t in "${targets[@]}"; do install_to "$t"; done
