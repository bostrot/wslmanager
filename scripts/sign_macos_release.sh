#!/bin/bash
# Sign, notarize and staple a built "WSL Manager.app", then package it as the
# release .dmg and .zip. Used by hand for a release that CI built ad-hoc, and
# by macos.yml once the signing secrets exist.
#
#   scripts/sign_macos_release.sh <path to .app or -macos.zip> <version> [outdir]
#
# Environment:
#   CODESIGN_IDENTITY  "Developer ID Application: Name (TEAMID)" — required.
#   NOTARY_PROFILE     keychain profile from `xcrun notarytool store-credentials`.
#                      Unset: sign only, no notarization (Gatekeeper will still
#                      refuse the app on first open).
#
# Why not `codesign --deep`: it re-signs nested code with the outer file's
# entitlements, so vmctl would lose its virtualization entitlement and the
# app would gain vmctl's. Every piece is signed on its own, inside out.
set -euo pipefail

INPUT="${1:?path to WSL Manager.app or the -macos.zip}"
VERSION="${2:?version, e.g. 2.0.0}"
OUT="${3:-$PWD}"
IDENTITY="${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to the Developer ID Application identity}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ "$INPUT" == *.zip ]]; then
  ditto -x -k "$INPUT" "$WORK/unpacked"
  APP=$(find "$WORK/unpacked" -maxdepth 1 -name '*.app' | head -1)
else
  cp -R "$INPUT" "$WORK/"
  APP="$WORK/$(basename "$INPUT")"
fi
[[ -d "$APP" ]] || { echo "no .app found in $INPUT" >&2; exit 1; }
# Finder's quarantine flag on a downloaded zip must not end up inside the
# signed bundle.
xattr -cr "$APP"

SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")

echo "==> Signing frameworks and dylibs"
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 \
  | while IFS= read -r -d '' item; do "${SIGN[@]}" "$item"; done

echo "==> Signing vmctl with the virtualization entitlement"
"${SIGN[@]}" --entitlements "$REPO/macos/vmctl/vmctl.entitlements" \
  "$APP/Contents/Resources/vmctl"

echo "==> Signing the app with its own entitlements"
"${SIGN[@]}" --entitlements "$REPO/macos/Runner/Release.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q com.apple.security.virtualization
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q com.apple.security.files.user-selected.read-write
codesign -d --entitlements - "$APP/Contents/Resources/vmctl" 2>/dev/null | grep -q com.apple.security.virtualization

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
else
  echo "==> NOTARY_PROFILE unset: skipping notarization"
fi

echo "==> Packaging"
mkdir -p "$OUT"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/wsl2-distro-manager-v$VERSION-macos.dmg"
ZIP="$OUT/wsl2-distro-manager-v$VERSION-macos.zip"
rm -f "$DMG" "$ZIP"
hdiutil create -volname "WSL Manager" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  # The dmg gets its own ticket so Finder trusts it before the app is copied.
  "${SIGN[@]}" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$DMG" "$ZIP"
echo "==> Done"
