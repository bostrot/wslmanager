#!/bin/bash
# Keep the cask in bostrot/homebrew-tap pointing at the bytes the GitHub
# release actually serves.
#
#   scripts/update_homebrew_cask.sh update <version> <path to the release dmg>
#
# Rewrites the cask's version and sha256, commits it, and reads it back to
# prove the change landed. The dmg it is handed must be the one the release
# serves: a cask whose checksum matches nothing fails every
# `brew install --cask bostrot/tap/wsl-manager` with "Cask reports different
# checksum" (bostrot/ai-tasks#63 — HOMEBREW_TAP_TOKEN had expired, so the
# cask could not follow the dmg that main builds kept replacing under 2.0.2).
# The workflow no longer replaces a released dmg at all, so the cask only
# ever moves forward to a new version.
#
# Environment:
#   TAP_TOKEN  token with contents:write on the tap — required.
#   TAP        owner/repo of the tap.         Default bostrot/homebrew-tap.
#   CASK_PATH  path to the cask in that repo. Default Casks/wsl-manager.rb.
#   GH_CLI     the gh binary; scripts/test_homebrew_cask.sh substitutes a
#              fake so the whole thing is exercised offline.
set -euo pipefail

MODE="${1:?update}"
TAP="${TAP:-bostrot/homebrew-tap}"
CASK_PATH="${CASK_PATH:-Casks/wsl-manager.rb}"
GH_CLI="${GH_CLI:-gh}"

# A secret pasted with a trailing newline yields an Authorization header
# Go's http client rejects outright ("invalid header field value"), which
# reads like a broken token rather than a stray byte. A token never contains
# whitespace, so strip it.
TOKEN=$(printf '%s' "${TAP_TOKEN:-}" | tr -d '[:space:]')

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# `gh: Bad credentials (HTTP 401)` on its own names neither the token that
# failed nor what it costs, so say both.
tap_hint() {
  {
    echo "Reading $CASK_PATH from $TAP with HOMEBREW_TAP_TOKEN failed."
    echo "If the token expired, mint a new one with contents:write on $TAP"
    echo "and reset the secret. Until then the cask keeps advertising"
    echo "whatever version and checksum it holds today."
  } >&2
}

read_cask() {
  GH_TOKEN="$TOKEN" "$GH_CLI" api "repos/$TAP/contents/$CASK_PATH" \
    -H "Accept: application/vnd.github.raw"
}

# The cask is a Ruby DSL, but the two lines we own are written one per line
# with two spaces of indent, and the workflow has always matched them that
# way. Reading them back with the same shape is what lets `update` prove its
# own edit rather than trusting sed.
cask_field() { # <file> <field>
  sed -n -E "s|^  $2 \"(.*)\"\$|\1|p" "$1" | head -1
}

if [ "$MODE" != "update" ]; then
  echo "::error::unknown mode '$MODE'; expected update" >&2
  exit 2
fi

VERSION="${2:?version, e.g. 2.0.2}"
DMG="${3:?path to the dmg the release serves}"

if [ -z "$TOKEN" ]; then
  echo "::error::HOMEBREW_TAP_TOKEN is empty once whitespace is stripped." >&2
  exit 1
fi
if [ ! -f "$DMG" ]; then
  echo "::error::$DMG does not exist; nothing to checksum." >&2
  exit 1
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

if ! read_cask > "$WORK/cask.rb" 2>"$WORK/err"; then
  cat "$WORK/err" >&2
  tap_hint
  exit 1
fi
BLOB=$(GH_TOKEN="$TOKEN" "$GH_CLI" api "repos/$TAP/contents/$CASK_PATH" --jq .sha)

if [ "$(cask_field "$WORK/cask.rb" version)" = "$VERSION" ] \
   && [ "$(cask_field "$WORK/cask.rb" sha256)" = "$SHA" ]; then
  echo "::notice::Cask is already at $VERSION with this checksum."
  exit 0
fi

sed -i '' -E "s|^  version \".*\"\$|  version \"$VERSION\"|" "$WORK/cask.rb"
sed -i '' -E "s|^  sha256 \".*\"\$|  sha256 \"$SHA\"|" "$WORK/cask.rb"

# A silent no-op here would publish a cask pointing at the new version with
# the old checksum.
[ "$(cask_field "$WORK/cask.rb" version)" = "$VERSION" ] \
  || { echo "::error::version line not updated" >&2; exit 1; }
[ "$(cask_field "$WORK/cask.rb" sha256)" = "$SHA" ] \
  || { echo "::error::sha256 line not updated" >&2; exit 1; }

GH_TOKEN="$TOKEN" "$GH_CLI" api --method PUT "repos/$TAP/contents/$CASK_PATH" \
  -f message="wsl-manager $VERSION" \
  -f sha="$BLOB" \
  -f content="$(base64 < "$WORK/cask.rb" | tr -d '\n')" --silent

# Read it back. A PUT against a blob sha someone else has already moved past
# fails loudly, but a tap that accepts the call and keeps the old content
# would otherwise leave a green build behind a cask no download matches —
# exactly the state this script exists to prevent.
if ! read_cask > "$WORK/published.rb" 2>"$WORK/err"; then
  cat "$WORK/err" >&2
  echo "::error::Cannot read $CASK_PATH back; the cask may not match the release." >&2
  exit 1
fi
if [ "$(cask_field "$WORK/published.rb" version)" != "$VERSION" ] \
   || [ "$(cask_field "$WORK/published.rb" sha256)" != "$SHA" ]; then
  echo "::error::$TAP still serves $(cask_field "$WORK/published.rb" version)" \
       "/ $(cask_field "$WORK/published.rb" sha256) after the write." >&2
  exit 1
fi

echo "::notice::Cask updated to $VERSION ($SHA)."
