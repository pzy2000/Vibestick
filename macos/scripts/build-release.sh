#!/usr/bin/env bash
set -euo pipefail

mode="${1:-dev}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
macos_root="$repo_root/macos"
dist="$macos_root/dist"
app="$dist/Vibestick.app"

"$macos_root/scripts/build-app-bundle.sh" "$mode" >/dev/null

if [[ "$mode" == "dev" ]]; then
  echo "Built development bundle at $app"
  exit 0
fi

: "${DEVELOPER_ID_INSTALLER:?Set DEVELOPER_ID_INSTALLER for release packaging.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE for xcrun notarytool.}"

pkg="$dist/Vibestick.pkg"
productbuild --component "$app" /Applications --sign "$DEVELOPER_ID_INSTALLER" "$pkg"
xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$pkg"

echo "Built notarized release package at $pkg"
