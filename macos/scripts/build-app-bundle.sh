#!/usr/bin/env bash
set -euo pipefail

mode="${1:-dev}"
case "$mode" in
  dev|release) ;;
  *)
    echo "Usage: $0 [dev|release]" >&2
    exit 64
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
macos_root="$repo_root/macos"
dist="$macos_root/dist"
app="$dist/Vibestick.app"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/vibestick-app-bundle.XXXXXX")"
staged_app="$build_root/Vibestick.app"
staged_ctl="$build_root/vibestickctl"
asset_root="$dist/packaging-assets"
iconset="$asset_root/Vibestick.iconset"
icon="$asset_root/Vibestick.icns"

cleanup() {
  rm -rf "$build_root"
}
trap cleanup EXIT

cd "$macos_root"
swift build -c release

rm -rf "$app" "$dist/vibestickctl" "$staged_app" "$staged_ctl"
mkdir -p "$staged_app/Contents/MacOS" \
  "$staged_app/Contents/Resources" \
  "$staged_app/Contents/Library/LaunchDaemons" \
  "$staged_app/Contents/Library/PrivilegedHelperTools" \
  "$asset_root"

if [[ ! -f "$icon" ]]; then
  "$macos_root/scripts/generate-packaging-assets.swift" iconset "$iconset"
  iconutil -c icns "$iconset" -o "$icon"
fi

install -m 644 "$macos_root/packaging/AppBundle/Info.plist" "$staged_app/Contents/Info.plist"
install -m 644 "$icon" "$staged_app/Contents/Resources/Vibestick.icns"
install -m 755 "$macos_root/.build/release/VibestickApp" "$staged_app/Contents/MacOS/VibestickApp"
install -m 755 "$macos_root/.build/release/VibestickDeviceWatcher" "$staged_app/Contents/MacOS/VibestickDeviceWatcher"
install -m 755 "$macos_root/.build/release/vibestickctl" "$staged_ctl"
install -m 755 "$macos_root/.build/release/VibestickHelper" "$staged_app/Contents/Library/PrivilegedHelperTools/com.pzy.vibestick.helper"
install -m 644 "$macos_root/packaging/LaunchDaemons/com.pzy.vibestick.helper.plist" "$staged_app/Contents/Library/LaunchDaemons/com.pzy.vibestick.helper.plist"

resource_bundle="$(find "$macos_root/.build" -path '*/release/VibestickMac_VibestickApp.bundle' -type d | head -n 1)"
if [[ -z "$resource_bundle" ]]; then
  echo "SwiftPM resource bundle for VibestickApp was not found." >&2
  exit 2
fi
ditto --norsrc --noextattr "$resource_bundle" "$staged_app/Contents/Resources/$(basename "$resource_bundle")"

clear_app_xattrs() {
  local bundle="$1"
  if command -v xattr >/dev/null 2>&1; then
    for _ in 1 2 3; do
      xattr -cr "$bundle" || true
      find "$bundle" -exec sh -c '
        for path do
          xattr -d "com.apple.fileprovider.fpfs#P" "$path" 2>/dev/null || true
          xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
          xattr -d com.apple.ResourceFork "$path" 2>/dev/null || true
        done
      ' sh {} +
      if ! xattr -lr "$bundle" 2>/dev/null | grep -Eq "com.apple.(FinderInfo|ResourceFork)|com.apple.fileprovider.fpfs#P"; then
        break
      fi
      sleep 0.1
    done
  fi
}

clear_app_xattrs "$staged_app"

if [[ "$mode" == "dev" ]]; then
  codesign --force --deep --sign - "$staged_app"
  clear_app_xattrs "$staged_app"
  xattr -c "$staged_ctl" 2>/dev/null || true
  codesign --force --sign - "$staged_ctl"
else
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION for release signing.}"
  codesign --force --options runtime --timestamp --deep --sign "$DEVELOPER_ID_APPLICATION" "$staged_app"
  clear_app_xattrs "$staged_app"
  xattr -c "$staged_ctl" 2>/dev/null || true
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$staged_ctl"
fi

mkdir -p "$dist"
ditto --norsrc --noextattr "$staged_app" "$app"
ditto --norsrc --noextattr "$staged_ctl" "$dist/vibestickctl"
clear_app_xattrs "$app"
xattr -c "$dist/vibestickctl" 2>/dev/null || true

echo "$app"
