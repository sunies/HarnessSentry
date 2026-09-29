#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
build_dir="$project_dir/.build/app-bundle"
app_bundle="$project_dir/dist/HarnessSentry.app"
icon_workspace="$build_dir/AppIcon.iconset"
icon_base="$build_dir/AppIcon-1024.png"

cd "$project_dir"
swift build -c "$configuration" --product HarnessSentry
swift build -c "$configuration" --product HarnessSentryHook
swift build -c "$configuration" --product HarnessSentryLabProbe
binary_dir="$(swift build -c "$configuration" --show-bin-path)"

rm -rf "$build_dir" "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources/Lab" "$icon_workspace"

cp "$binary_dir/HarnessSentry" "$app_bundle/Contents/MacOS/HarnessSentry"
cp "$binary_dir/HarnessSentryHook" "$app_bundle/Contents/MacOS/HarnessSentryHook"
cp "$binary_dir/HarnessSentryLabProbe" "$app_bundle/Contents/MacOS/HarnessSentryLabProbe"
cp "$project_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_dir/LICENSE" "$app_bundle/Contents/Resources/LICENSE"
cp "$project_dir/NOTICE" "$app_bundle/Contents/Resources/NOTICE"
cp -R "$project_dir/Resources/HarnessIcons" "$app_bundle/Contents/Resources/HarnessIcons"
cp "$project_dir/Scripts/zcode-lab-capture.sh" "$app_bundle/Contents/Resources/Lab/zcode-lab-capture.sh"
cp "$project_dir/Scripts/create-zcode-decoy-repo.sh" "$app_bundle/Contents/Resources/Lab/create-zcode-decoy-repo.sh"
cp "$project_dir/docs/zcode-3.12.3-lab.md" "$app_bundle/Contents/Resources/Lab/README.md"

swift "$project_dir/Scripts/generate-icon.swift" "$icon_base"
for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  target_size="${entry%% *}"
  target_name="${entry#* }"
  /usr/bin/sips -z "$target_size" "$target_size" "$icon_base" --out "$icon_workspace/$target_name" >/dev/null
done
/usr/bin/iconutil -c icns "$icon_workspace" -o "$app_bundle/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --deep --sign - "$app_bundle"
echo "$app_bundle"
