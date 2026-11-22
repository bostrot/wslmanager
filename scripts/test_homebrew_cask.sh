#!/usr/bin/env bash
# Offline check of scripts/update_homebrew_cask.sh against a fake `gh` that
# serves a cask the way bostrot/homebrew-tap does. No network, no token.
#
# The cases that matter are the unhappy ones: an expired HOMEBREW_TAP_TOKEN
# is what broke `brew install --cask bostrot/tap/wsl-manager` on 2026-09-09
# (bostrot/ai-tasks#63), and it broke it quietly — the build had already
# replaced the dmg the published cask pointed at. The attach step's guard at
# the bottom is what keeps that from happening again, for this tap and for
# Homebrew's own homebrew/cask alike.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/update_homebrew_cask.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stands in for the GitHub CLI. FAKE_STATE is the cask the tap serves;
# FAKE_MODE=401 fails every call the way an expired token does; and
# FAKE_IGNORE_PUT=1 accepts a write without keeping it, which is the one
# failure a PUT's own exit code cannot report.
cat > "$WORK/bin/gh" <<'FAKE'
#!/bin/bash
set -euo pipefail
if [ "${FAKE_MODE:-ok}" = "401" ]; then
  echo "gh: Bad credentials (HTTP 401)" >&2
  exit 1
fi
put=0; content=""
for arg in "$@"; do
  case "$arg" in
    PUT) put=1 ;;
    content=*) content="${arg#content=}" ;;
  esac
done
if [ "$put" = 1 ]; then
  echo "PUT" >> "$FAKE_STATE.calls"
  [ "${FAKE_IGNORE_PUT:-0}" = "1" ] || base64 -d <<<"$content" > "$FAKE_STATE"
  exit 0
fi
if [ "${1:-}" = "release" ]; then
  case "${2:-}" in
    view)   [ -n "${FAKE_ASSETS:-}" ] || exit 1; printf '%s\n' $FAKE_ASSETS ;;
    upload) echo "UPLOAD" >> "$FAKE_STATE.calls" ;;
  esac
  exit 0
fi
case " $* " in
  *" --jq .sha "*) echo "blob0000" ;;
  *) cat "$FAKE_STATE" ;;
esac
FAKE
chmod +x "$WORK/bin/gh"
export GH_CLI="$WORK/bin/gh"
export TAP="bostrot/homebrew-tap" CASK_PATH="Casks/wsl-manager.rb"
export FAKE_STATE="$WORK/cask.rb"

DMG="$WORK/wsl-manager.dmg"
printf 'not really a disk image' > "$DMG"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

seed() { # <version> <sha256>
  rm -f "$FAKE_STATE.calls"
  cat > "$FAKE_STATE" <<CASK
cask "wsl-manager" do
  version "$1"
  sha256 "$2"

  url "https://github.com/bostrot/wslmanager/releases/download/v#{version}/wsl2-distro-manager-v#{version}-macos.dmg"
  name "WSL Manager"
  depends_on arch: :arm64
end
CASK
}
STALE="d25d60ce2429ecf6be63b40cba7a6112e736ec980806cc3c26031a2af0b4f7cb"

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# update -----------------------------------------------------------------
if TAP_TOKEN=t "$SCRIPT" check >/dev/null 2>"$WORK/err"; then
  fail "the removed check mode is rejected"
fi
grep -q "expected update" "$WORK/err" || fail "an unknown mode names the one that exists"
ok "only update is a mode"

seed 2.0.1 "$STALE"
TAP_TOKEN=t "$SCRIPT" update 2.0.2 "$DMG" >/dev/null
grep -qx "  version \"2.0.2\"" "$FAKE_STATE" || fail "update writes the new version"
grep -qx "  sha256 \"$SHA\"" "$FAKE_STATE" || fail "update writes the dmg's checksum"
grep -q 'url "https://github.com/bostrot' "$FAKE_STATE" || fail "update leaves the rest of the cask alone"
ok "update points the cask at the dmg it was handed"

rm -f "$FAKE_STATE.calls"
TAP_TOKEN=t "$SCRIPT" update 2.0.2 "$DMG" >/dev/null
[ ! -f "$FAKE_STATE.calls" ] || fail "a cask already at this version and checksum is not rewritten"
ok "update is a no-op when the cask already matches"

seed 2.0.1 "$STALE"
if FAKE_MODE=401 TAP_TOKEN=t "$SCRIPT" update 2.0.2 "$DMG" >/dev/null 2>"$WORK/err"; then
  fail "update fails when the tap cannot be read"
fi
grep -q "contents:write" "$WORK/err" || fail "update's 401 says how to fix the token"
ok "update fails loudly on an expired token"

seed 2.0.1 "$STALE"
if FAKE_IGNORE_PUT=1 TAP_TOKEN=t "$SCRIPT" update 2.0.2 "$DMG" >/dev/null 2>"$WORK/err"; then
  fail "update fails when the write is accepted but not kept"
fi
grep -q "still serves 2.0.1" "$WORK/err" || fail "update names what the tap still serves"
ok "update reads the cask back instead of trusting the write"

# A cask whose lines this script cannot recognise must not be published
# half-rewritten: version bumped, checksum left behind.
rm -f "$FAKE_STATE.calls"
cat > "$FAKE_STATE" <<'CASK'
cask "wsl-manager" do
  version "2.0.1"
  sha256 :no_check
end
CASK
if TAP_TOKEN=t "$SCRIPT" update 2.0.2 "$DMG" >/dev/null 2>"$WORK/err"; then
  fail "update refuses a cask it cannot rewrite"
fi
grep -q "sha256 line not updated" "$WORK/err" || fail "update says which line it could not write"
[ ! -f "$FAKE_STATE.calls" ] || fail "update publishes nothing when it cannot rewrite both lines"
ok "update refuses to publish a half-rewritten cask"

if TAP_TOKEN=t "$SCRIPT" update 2.0.2 "$WORK/absent.dmg" >/dev/null 2>"$WORK/err"; then
  fail "update refuses a dmg that is not there"
fi
grep -q "does not exist" "$WORK/err" || fail "update names the missing dmg"
ok "update refuses to checksum a dmg that is not there"

# The attach step's guard ---------------------------------------------
# Run the workflow's own shell, not a copy of it: what this is really
# checking is that a rebuild never replaces a dmg that is on the release. Two
# casks point at that dmg by checksum — this tap and Homebrew's own
# homebrew/cask, which BrewTestBot bumps and nothing in the workflow can
# rewrite — so a replaced dmg fails `brew upgrade wsl-manager` for everyone
# until the next version (2.3.0, 2026-09-17).
awk '/^      - name: Attach to release \(main only\)$/{f=1} f&&/^        run: [|]$/{r=1;next} r&&NF&&!/^          /{exit} r' \
  .github/workflows/macos.yml | sed -e 's|^          ||' \
  -e 's|\${{ steps.get_version.outputs.version }}|2.0.2|g' > "$WORK/attach.sh"
[ -s "$WORK/attach.sh" ] || fail "macos.yml still has a run block under 'Attach to release (main only)'"
! grep -q -- '--clobber' "$WORK/attach.sh" || fail "attach no longer passes --clobber"

attach() { # <assets> <has_signing>
  rm -f "$FAKE_STATE.calls"
  PATH="$WORK/bin:$PATH" FAKE_ASSETS="$1" HAS_SIGNING="$2" bash "$WORK/attach.sh" >/dev/null
  grep -q UPLOAD "$FAKE_STATE.calls" 2>/dev/null && echo uploaded || echo skipped
}
DMGS="wsl2-distro-manager-v2.0.2-macos.dmg wsl2-distro-manager-v2.0.2-setup.exe"
WINONLY="wsl2-distro-manager-v2.0.2-setup.exe"

[ "$(attach "" true)" = uploaded ] \
  || fail "a release with no assets yet gets the mac ones"
ok   "attach uploads when the release carries no dmg"

[ "$(attach "$WINONLY" true)" = uploaded ] \
  || fail "a release with only the Windows asset gets the mac ones"
ok   "attach uploads when only the Windows installer is there"

[ "$(attach "$DMGS" true)" = skipped ] \
  || fail "a signed rebuild never replaces a published dmg"
ok   "attach leaves a published dmg alone even for a signed build"

[ "$(attach "$DMGS" false)" = skipped ] \
  || fail "an ad-hoc build never replaces a published dmg"
ok   "attach leaves a published dmg alone for an unsigned build"

[ "$(attach "" false)" = skipped ] \
  || fail "an ad-hoc build is never pinned to a release"
ok   "attach uploads nothing from an unsigned build"

echo "all homebrew cask checks passed"
