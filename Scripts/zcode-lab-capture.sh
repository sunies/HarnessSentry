#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  print -u2 "用法：$0 <ZCode-3.12.3.app> <隔离测试仓库> [HarnessSentry.sqlite]"
  exit 2
fi

zcode_app="${1:A}"
workspace="${2:A}"
database="${3:-}"
script_dir="${0:A:h}"
project_root="${script_dir:h}"

if [[ ! -d "$zcode_app" || ! -f "$zcode_app/Contents/Info.plist" ]]; then
  print -u2 "找不到 ZCode.app：$zcode_app"
  exit 2
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$zcode_app/Contents/Info.plist" 2>/dev/null || true)
if [[ "$version" != "3.12.3" ]]; then
  print -u2 "拒绝启动：实验只允许已核验的问题版本 3.12.3，当前为 ${version:-未知版本}。"
  exit 2
fi
if [[ ! -f "$workspace/.harnesssentry-zcode-decoy" ]]; then
  print -u2 "拒绝监测真实项目：测试仓库必须包含 .harnesssentry-zcode-decoy 标记。"
  exit 2
fi

bundled_probe="$script_dir/../../MacOS/HarnessSentryLabProbe"
if [[ -x "$bundled_probe" ]]; then
  probe="${bundled_probe:A}"
else
  cd "$project_root"
  swift build -c release --product HarnessSentryLabProbe >/dev/null
  probe="$project_root/.build/release/HarnessSentryLabProbe"
fi
probe_args=(--tool zcode --workspace "$workspace")
if [[ -n "$database" ]]; then
  probe_args+=(--database "${database:A}")
fi

print "HarnessSentry ZCode 3.12.3 隔离复现实验"
print "  App：$zcode_app"
print "  仓库：$workspace"
print "  范围：仅 ZCode.app 内进程；不保存源码、Prompt、请求正文或原始 JSONL"
print "  停止：Control-C"
print
print "macOS 将要求管理员权限；运行本命令的终端还需要开启“完全磁盘访问权限”。"

sudo /usr/bin/eslogger \
  --select "$zcode_app/Contents" \
  open close create write rename unlink readdir exec \
  | "$probe" "${probe_args[@]}"
