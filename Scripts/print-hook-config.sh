#!/bin/zsh
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: Scripts/print-hook-config.sh <adapter> [HarnessSentryHook path]

Adapters: codex, claude-code, workbuddy, qoder, zcode, cursor, windsurf, copilot,
          gemini-cli, qwen-code, continue, iflow-cli, kimi-cli, goose, cline, trae

Prints the target's Hook JSON, TOML block, or owned plugin source to stdout. This script never reads or modifies
any user or project configuration.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

adapter="$1"
case "$adapter" in
  codex|claude-code|workbuddy|qoder|zcode|cursor|windsurf|copilot|gemini-cli|qwen-code|continue|iflow-cli|kimi-cli|goose|cline|trae) ;;
  *) usage; exit 2 ;;
esac

project_dir="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -eq 2 ]]; then
  hook_binary="$2"
elif [[ -x "/Applications/HarnessSentry.app/Contents/MacOS/HarnessSentryHook" ]]; then
  hook_binary="/Applications/HarnessSentry.app/Contents/MacOS/HarnessSentryHook"
elif [[ -x "$project_dir/dist/HarnessSentry.app/Contents/MacOS/HarnessSentryHook" ]]; then
  hook_binary="$project_dir/dist/HarnessSentry.app/Contents/MacOS/HarnessSentryHook"
else
  cd "$project_dir"
  swift build --product HarnessSentryHook >&2
  binary_dir="$(swift build --show-bin-path)"
  hook_binary="$binary_dir/HarnessSentryHook"
fi

if [[ ! -x "$hook_binary" ]]; then
  echo "HarnessSentryHook is not executable: $hook_binary" >&2
  exit 1
fi

exec "$hook_binary" --print-config "$adapter"
