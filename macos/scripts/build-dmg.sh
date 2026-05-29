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
asset_root="$dist/packaging-assets"
background="$asset_root/Vibestick-dmg-background.png"

"$macos_root/scripts/build-app-bundle.sh" "$mode" >/dev/null
"$macos_root/scripts/generate-packaging-assets.swift" dmg-background "$background"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
volume_name="Vibestick $version"
dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/vibestick-dmg-root.XXXXXX")"
rw_dmg="$dist/Vibestick-$version.rw.dmg"
final_dmg="$dist/Vibestick-$version.dmg"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibestick-dmg.XXXXXX")"
device=""

cleanup() {
  if [[ -n "$device" ]]; then
    hdiutil detach "$device" -quiet || true
  fi
  rm -rf "$mount_dir" "$dmg_root" "$rw_dmg"
}
trap cleanup EXIT

clear_bundle_xattrs() {
  local bundle="$1"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$bundle" || true
    xattr -rd com.apple.FinderInfo "$bundle" 2>/dev/null || true
    xattr -rd "com.apple.fileprovider.fpfs#P" "$bundle" 2>/dev/null || true
    xattr -rd com.apple.ResourceFork "$bundle" 2>/dev/null || true
    find "$bundle" -exec sh -c '
      for path do
        xattr -d "com.apple.fileprovider.fpfs#P" "$path" 2>/dev/null || true
        xattr -d com.apple.FinderInfo "$path" 2>/dev/null || true
        xattr -d com.apple.ResourceFork "$path" 2>/dev/null || true
      done
    ' sh {} +
  fi
}

sign_bundle() {
  local bundle="$1"
  clear_bundle_xattrs "$bundle"
  if [[ "$mode" == "release" ]]; then
    : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION for release app signing.}"
    codesign --force --options runtime --timestamp --deep --sign "$DEVELOPER_ID_APPLICATION" "$bundle"
  else
    codesign --force --deep --sign - "$bundle"
  fi
  clear_bundle_xattrs "$bundle"
}

rm -rf "$rw_dmg" "$final_dmg"
mkdir -p "$dmg_root"
ditto --norsrc --noextattr "$app" "$dmg_root/Vibestick.app"
ln -s /Applications "$dmg_root/Applications"
cp "$background" "$dmg_root/Vibestick.app/Contents/Resources/Vibestick-dmg-background.png"

hdiutil create \
  -srcfolder "$dmg_root" \
  -volname "$volume_name" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size 220m \
  "$rw_dmg" >/dev/null

attach_output="$(hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen -mountpoint "$mount_dir")"
device="$(awk '/Apple_HFS|APFS/ {print $1; exit}' <<<"$attach_output")"
if [[ -z "$device" ]]; then
  echo "Could not find mounted DMG device." >&2
  exit 1
fi

osascript <<APPLESCRIPT
tell application "Finder"
  set dmgFolder to POSIX file "$mount_dir" as alias
  open dmgFolder
  set dmgWindow to container window of dmgFolder
  set current view of dmgWindow to icon view
  try
    set toolbar visible of dmgWindow to false
  end try
  try
    set statusbar visible of dmgWindow to false
  end try
  set bounds of dmgWindow to {120, 120, 760, 540}
  set viewOptions to the icon view options of dmgWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 96
  set background picture of viewOptions to POSIX file "$mount_dir/Vibestick.app/Contents/Resources/Vibestick-dmg-background.png"
  set position of item "Vibestick.app" of dmgFolder to {160, 210}
  set position of item "Applications" of dmgFolder to {480, 210}
  update dmgFolder without registering applications
  delay 1
end tell
APPLESCRIPT

rm -rf "$mount_dir/.fseventsd"
sign_bundle "$mount_dir/Vibestick.app"
sync
hdiutil detach "$device" -quiet
device=""

hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$final_dmg" >/dev/null
hdiutil verify "$final_dmg" >/dev/null
clear_bundle_xattrs "$app"

if [[ "$mode" == "release" ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION for release DMG signing.}"
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE for xcrun notarytool.}"
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" "$final_dmg"
  xcrun notarytool submit "$final_dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$final_dmg"
fi

echo "Built DMG at $final_dmg"
