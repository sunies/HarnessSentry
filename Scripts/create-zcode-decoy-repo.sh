#!/bin/zsh
set -euo pipefail

target="${1:-/tmp/HarnessSentry-ZCodeLab-3.12.3/decoy-workspace}"
target="${target:A}"
if [[ -e "$target" ]]; then
  print -u2 "目标已存在，未覆盖：$target"
  exit 2
fi

mkdir -p "$target/Sources" "$target/Fixtures"
touch "$target/.harnesssentry-zcode-decoy"
print 'import Foundation\n\nprint("HarnessSentry decoy")' > "$target/Sources/main.swift"
print '{"purpose":"isolated ZCode 3.12.3 reproduction","containsRealCode":false}' > "$target/Fixtures/manifest.json"
git -C "$target" init -q
git -C "$target" add .
git -C "$target" -c user.name='HarnessSentry Lab' -c user.email='lab@localhost' commit -q -m 'decoy fixture'
print "$target"
