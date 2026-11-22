#!/bin/bash
# Build the macOS app together with the vmctl virtualization helper.
#
# vmctl needs the com.apple.security.virtualization entitlement to run VMs,
# so it is signed explicitly (ad-hoc by default; set CODESIGN_IDENTITY for a
# real identity). The helper is copied into the app bundle's Resources so
# the app finds it next to itself; during `flutter run` it is picked up from
# ~/Library/Application Support/WSLManager/bin/vmctl or $VMCTL_PATH instead.
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> Building vmctl (release)"
(cd macos/vmctl && swift build -c release)
VMCTL_BIN=macos/vmctl/.build/release/vmctl

echo "==> Signing vmctl with virtualization entitlement"
codesign --force --sign "$IDENTITY" \
  --entitlements macos/vmctl/vmctl.entitlements \
  "$VMCTL_BIN"

# A stable copy for `flutter run` debug sessions, which have no bundle to
# carry the helper.
DEV_BIN="$HOME/Library/Application Support/WSLManager/bin"
mkdir -p "$DEV_BIN"
# Atomic install (copy + rename): overwriting a signed executable in place
# poisons the kernel's code-signature cache for that inode, after which every
# exec of it dies with SIGKILL until the file is replaced.
cp "$VMCTL_BIN" "$DEV_BIN/vmctl.tmp"
mv -f "$DEV_BIN/vmctl.tmp" "$DEV_BIN/vmctl"
echo "==> vmctl installed for dev runs at $DEV_BIN/vmctl"

if [[ "${VMCTL_ONLY:-0}" == "1" ]]; then
  echo "==> vmctl built at $VMCTL_BIN"
  exit 0
fi

echo "==> Building Flutter macOS app"
# GITHUB_CLIENT_ID overrides the OAuth client id for snippet sharing that
# is bundled in lib/api/github_publish.dart (doc/github-oauth-setup.md). It
# is public information, so a plain env var and never a secret. Left unset
# the define is passed empty, which the app treats as "use the bundled id".
flutter build macos --release \
  --dart-define=GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"

APP=$(ls -d build/macos/Build/Products/Release/*.app | head -1)
echo "==> Bundling vmctl into $APP"
cp "$VMCTL_BIN" "$APP/Contents/Resources/vmctl"
codesign --force --sign "$IDENTITY" \
  --entitlements macos/vmctl/vmctl.entitlements \
  "$APP/Contents/Resources/vmctl"

# Re-seal the outer bundle after modifying its contents. Not --deep, and
# with the app's own entitlements: a bare --force re-sign strips them, which
# silently removes com.apple.security.virtualization from the app.
codesign --force --sign "$IDENTITY" \
  --entitlements macos/Runner/Release.entitlements \
  "$APP"
echo "==> Done: $APP"
