#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$project_dir/dist"
app_bundle="$dist_dir/HarnessSentry.app"

"$project_dir/Scripts/build-app.sh" release

info_plist="$app_bundle/Contents/Info.plist"
app_binary="$app_bundle/Contents/MacOS/HarnessSentry"
/usr/bin/plutil -lint "$info_plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$app_bundle"

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
architecture="$(/usr/bin/uname -m)"

if [[ -z "$version" || "$version" == *[^A-Za-z0-9._+-]* ]]; then
  echo "Invalid CFBundleShortVersionString for a release filename: $version" >&2
  exit 1
fi
if [[ -z "$architecture" || "$architecture" == *[^A-Za-z0-9_-]* ]]; then
  echo "Invalid architecture for a release filename: $architecture" >&2
  exit 1
fi

archive_name="HarnessSentry-${version}-${architecture}.zip"
archive_path="$dist_dir/$archive_name"
checksum_path="$archive_path.sha256"

if [[ -e "$archive_path" || -e "$checksum_path" ]]; then
  echo "Refusing to overwrite an existing release artifact:" >&2
  [[ -e "$archive_path" ]] && echo "  $archive_path" >&2
  [[ -e "$checksum_path" ]] && echo "  $checksum_path" >&2
  echo "Move or rename the existing artifact, or bump CFBundleShortVersionString before rebuilding." >&2
  exit 1
fi

temporary_dir="$(/usr/bin/mktemp -d "$dist_dir/.HarnessSentry-release.XXXXXX")"
trap '/bin/rm -rf "$temporary_dir"' EXIT INT TERM
temporary_archive="$temporary_dir/$archive_name"
temporary_checksum="$temporary_dir/$archive_name.sha256"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$temporary_archive"
/usr/bin/unzip -tq "$temporary_archive" >/dev/null
digest="$(/usr/bin/shasum -a 256 "$temporary_archive" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$digest" "$archive_name" > "$temporary_checksum"

# The second check protects against another packager creating the same version
# while compression was running.
if [[ -e "$archive_path" || -e "$checksum_path" ]]; then
  echo "A release artifact with this version appeared while packaging; nothing was overwritten." >&2
  exit 1
fi

/bin/mv "$temporary_archive" "$archive_path"
/bin/mv "$temporary_checksum" "$checksum_path"

/usr/bin/plutil -lint "$info_plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$app_bundle"

echo "$archive_path"
echo "$checksum_path"
