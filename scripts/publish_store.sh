#!/usr/bin/env bash
# Publishes an MSIX to the Microsoft Store through the legacy submission API,
# and refuses whenever that API cannot carry the app's pricing unchanged.
#
# The API (manage.devcenter.microsoft.com/v1.0) predates Partner Center's
# market groups. For an app priced by market groups it returns
# `pricing.priceId: "Base"` and no market overrides — not "tier not set", but
# "this model cannot express what Partner Center holds". The whole object has
# to go back on PUT ("Pricing data was not provided" otherwise), and a PUT
# that carries "Base" is rejected. On 2026-09-07 this script answered that by
# deleting priceId and sending the rest; the API accepted a pricing object
# with no base tier and no overrides and published WSL Manager as FREE in all
# 240 markets, every market group gone (2.0.1 submission …31420, then 2.0.2
# as Submission 72). The comment that used to sit here — "the prices already
# sit on it server-side and stay exactly as they were" — was wrong.
#
# So: when the clone comes back with "Base", stop. The package then has to be
# updated by hand in Partner Center, where the pricing is left alone. When the
# clone carries a real tier, the object round-trips and publishing is safe.
#
# It also no longer deletes a pending submission it finds. On 2026-09-08 the
# one it deleted was the previous release, still in certification.
#
# The way out, documented by Microsoft only between the lines: the API does
# accept a base tier and per-market tiers *stated in its own terms*
# (priceId "Tier1012".."Tier1424" for the advanced model). With PRICING_FILE
# set, store/pricing.json is written into the clone (scripts/store_pricing.jq)
# instead of echoing what the API could not read, so the round trip is
# deterministic and the prices live in git. DRY_RUN=1 proves that without
# risk: it creates a submission, PUTs, reads the submission back, reports
# what the API stored against what was sent, and deletes the submission —
# nothing is uploaded and nothing is committed. Run it after any pricing
# change and before trusting a release to it.
#
# Required environment:
#   STORE_TENANT_ID  STORE_CLIENT_ID  STORE_CLIENT_SECRET  STORE_APP_ID
# Optional environment:
#   PRICING_FILE  path to a pricing file (see store/pricing.json); without it
#                 the clone's pricing must round-trip on its own (see above)
#   DRY_RUN=1     create, PUT, read back, report, delete; never upload/commit
# Argument:
#   $1  path to the .msix to publish (still required in a dry run, unused)
set -euo pipefail

MSIX_PATH="${1:?usage: publish_store.sh <path-to-msix>}"
[ -f "$MSIX_PATH" ] || { echo "No such package: $MSIX_PATH" >&2; exit 1; }

for var in STORE_TENANT_ID STORE_CLIENT_ID STORE_CLIENT_SECRET STORE_APP_ID; do
  [ -n "${!var:-}" ] || { echo "$var is not set" >&2; exit 1; }
done

API="https://manage.devcenter.microsoft.com/v1.0/my/applications"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# curl wrapper that keeps the body and the status code apart, so a failure
# reports what the API actually said instead of an empty string.
request() {
  local method="$1" url="$2" body="${3:-}"
  local args=(-sS -X "$method" -H "Authorization: Bearer $TOKEN"
              -o "$WORK/body" -w '%{http_code}')
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  else
    args+=(-H "Content-Length: 0")
  fi
  local code
  code=$(curl "${args[@]}" "$url")
  cat "$WORK/body"
  [[ "$code" =~ ^2 ]] || {
    # Callers that only want the status discard stdout, so the API's own
    # explanation has to reach the log by another route.
    echo "$method $url -> HTTP $code" >&2
    cat "$WORK/body" >&2; echo >&2
    return 1
  }
}

echo "Authenticating..."
TOKEN=$(curl -sS -X POST "https://login.microsoftonline.com/$STORE_TENANT_ID/oauth2/token" \
  -d grant_type=client_credentials \
  --data-urlencode "client_id=$STORE_CLIENT_ID" \
  --data-urlencode "client_secret=$STORE_CLIENT_SECRET" \
  --data-urlencode "resource=https://manage.devcenter.microsoft.com" \
  | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || { echo "Could not obtain an access token" >&2; exit 1; }

# A pending submission is not ours to remove: it may be the previous release
# still in certification, or a draft somebody is editing in Partner Center.
# Whoever owns it decides; this run just says so and stops.
PENDING=$(request GET "$API/$STORE_APP_ID" | jq -r '.pendingApplicationSubmission.id // empty')
if [ -n "$PENDING" ]; then
  echo "Submission $PENDING is pending (in certification, or a Partner Center draft)." >&2
  echo "Not deleting it. Let it finish or remove it by hand, then re-run." >&2
  echo "https://partner.microsoft.com/dashboard/products/$STORE_APP_ID/submissions/$PENDING" >&2
  exit 1
fi

echo "Creating submission..."
SUBMISSION=$(request POST "$API/$STORE_APP_ID/submissions")
SUBMISSION_ID=$(jq -r '.id' <<<"$SUBMISSION")
UPLOAD_URL=$(jq -r '.fileUploadUrl' <<<"$SUBMISSION")
[ -n "$SUBMISSION_ID" ] && [ "$SUBMISSION_ID" != "null" ] || {
  echo "The API returned no submission id" >&2; exit 1; }

# From here on a failure would strand a pending submission, so clean it up.
cleanup_submission() {
  echo "Removing the half-finished submission $SUBMISSION_ID..." >&2
  request DELETE "$API/$STORE_APP_ID/submissions/$SUBMISSION_ID" >/dev/null 2>&1 || true
}
trap 'cleanup_submission; rm -rf "$WORK"' EXIT

MSIX_NAME="$(basename "$MSIX_PATH")"
PRICE_ID=$(jq -r '.pricing.priceId // empty' <<<"$SUBMISSION")

if [ -n "${PRICING_FILE:-}" ]; then
  # Stated pricing: the file decides, the clone only contributes what the
  # file is silent about (see store_pricing.jq).
  [ -f "$PRICING_FILE" ] || { echo "No such pricing file: $PRICING_FILE" >&2; exit 1; }
  WANT_PRICE_ID=$(jq -r '.priceId // empty' "$PRICING_FILE")
  # "Free" is allowed, and only here: what went wrong in September was a Free
  # nobody asked for, produced by sending a pricing object with no base tier
  # at all. A file that says "Free" in as many words is the opposite of that,
  # and it is how the listing is free on purpose (store/pricing.json says so;
  # the paid tiers wait in store/pricing-paid.json — see
  # doc/microsoft-store-freemium.md). Everything else — "Base", empty,
  # anything unrecognised — is still refused.
  [[ "$WANT_PRICE_ID" =~ ^Tier[0-9]+$ || "$WANT_PRICE_ID" = "Free" ]] \
    || { echo "$PRICING_FILE: priceId must be a Tier id or Free, got \"$WANT_PRICE_ID\"" >&2; exit 1; }
  echo "Pricing from $PRICING_FILE: base $WANT_PRICE_ID, $(jq '.marketSpecificPricings | length' "$PRICING_FILE") market overrides (clone reported \"${PRICE_ID:-<none>}\")."
  PRICED=$(jq --from-file "$(dirname "$0")/store_pricing.jq" \
             --argjson pricing "$(jq -c . "$PRICING_FILE")" <<<"$SUBMISSION")
else
  # The one check that matters without a file. "Base" means the API could
  # not read the pricing out of Partner Center, so nothing this script sends
  # can put it back; the only pricing a PUT can preserve is one the clone
  # states in full.
  if [ -z "$PRICE_ID" ] || [ "$PRICE_ID" = "Base" ]; then
    cat >&2 <<EOF
Refusing to publish: the submission API reports the base price as "${PRICE_ID:-<none>}".
That is what it returns for a product on "Pricing Version 2" (prices set in the
Partner Center UI), which this API cannot express. Publishing through it would
replace the pricing with Free in every market (as happened on 2026-09-07/08).
Either update the package by hand in Partner Center (pricing stays untouched
there), or state the pricing in store/pricing.json and run with PRICING_FILE
after a green DRY_RUN:
https://partner.microsoft.com/dashboard/products/$STORE_APP_ID/overview
EOF
    exit 1
  fi
  PRICED="$SUBMISSION"
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  # Packages untouched: nothing to upload, so the submission can be deleted
  # cleanly afterwards. Only the pricing goes out.
  echo "DRY RUN: sending pricing only, no package change."
  BODY="$PRICED"
else
  echo "Replacing the packages with $MSIX_NAME..."
  BODY=$(jq --arg name "$MSIX_NAME" '
    .applicationPackages = (
        [ (.applicationPackages // [])[] | .fileStatus = "PendingDelete" ]
        + [ { fileName: $name,
              fileStatus: "PendingUpload",
              minimumDirectXVersion: "None",
              minimumSystemRam: "None" } ]
      )
  ' <<<"$PRICED")
fi

# Belt and braces: the pricing block leaves exactly as decided above — the
# clone's own when there is no file, the file's when there is.
[ "$(jq -c .pricing <<<"$BODY")" = "$(jq -c .pricing <<<"$PRICED")" ] \
  || { echo "Refusing to send a body whose pricing differs from what was decided" >&2; exit 1; }

request PUT "$API/$STORE_APP_ID/submissions/$SUBMISSION_ID" "$BODY" >/dev/null

if [ "${DRY_RUN:-0}" = "1" ]; then
  # The proof: what did the API store? Read the submission back and compare
  # with what was sent. A "Base" here, or a different tier or override set,
  # means a real publish would not have preserved the prices.
  STORED=$(request GET "$API/$STORE_APP_ID/submissions/$SUBMISSION_ID")
  SENT_PRICING=$(jq -cS '.pricing | {priceId, marketSpecificPricings}' <<<"$BODY")
  GOT_PRICING=$(jq -cS '.pricing | {priceId, marketSpecificPricings}' <<<"$STORED")
  echo "Sent:   $SENT_PRICING"
  echo "Stored: $GOT_PRICING"
  # Delete before judging, so a failed dry run never leaves a submission
  # behind to block the next real one.
  request DELETE "$API/$STORE_APP_ID/submissions/$SUBMISSION_ID" >/dev/null
  trap 'rm -rf "$WORK"' EXIT
  if [ "$SENT_PRICING" = "$GOT_PRICING" ] && [ "$(jq -r .priceId <<<"$GOT_PRICING")" != "Base" ]; then
    echo "DRY RUN OK: the API stored the pricing exactly as sent. Dry-run submission deleted."
    exit 0
  fi
  echo "DRY RUN FAILED: the API did not store the pricing as sent. Dry-run submission deleted." >&2
  exit 1
fi

echo "Uploading the package..."
( cd "$(dirname "$MSIX_PATH")" && zip -q -j "$WORK/package.zip" "$MSIX_NAME" )
UPLOAD_CODE=$(curl -sS -X PUT -H "x-ms-blob-type: BlockBlob" \
  --data-binary "@$WORK/package.zip" -o /dev/null -w '%{http_code}' "$UPLOAD_URL")
[[ "$UPLOAD_CODE" =~ ^2 ]] || { echo "Package upload -> HTTP $UPLOAD_CODE" >&2; exit 1; }

echo "Committing..."
COMMIT=$(request POST "$API/$STORE_APP_ID/submissions/$SUBMISSION_ID/commit")
STATUS=$(jq -r '.status // "unknown"' <<<"$COMMIT")
echo "Submission $SUBMISSION_ID is now $STATUS."

# Committed: the submission belongs to Partner Center now, not to the trap.
trap 'rm -rf "$WORK"' EXIT

case "$STATUS" in
  CommitStarted|PendingPublication|Publishing|Published) ;;
  *) echo "Unexpected status after commit: $STATUS" >&2; exit 1 ;;
esac

echo "https://partner.microsoft.com/dashboard/products/$STORE_APP_ID/submissions/$SUBMISSION_ID"
