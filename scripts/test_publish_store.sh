#!/usr/bin/env bash
# Offline check of scripts/publish_store.sh against a fake `curl` that answers
# the way the Store submission API does. No network, no credentials, and no
# real submission is ever created, changed or deleted.
#
# The cases that matter are the pending ones. On 2026-11-19 v2.6.1 never
# reached the Store: a submission made by hand in Partner Center was pending,
# the script refused, and nothing ran it again. A pending draft is now
# adopted, one in certification defers the run without failing it, and a
# version the Store already has is a no-op — which is what lets the daily
# catch-up in publish-store.yml run the same script safely.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/publish_store.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stands in for curl. A response is the file $FAKE_STATE/<METHOD>_<path>.json,
# where <path> is the URL below .../my/applications/ with / turned into _
# (the package upload is "blob"). Every call is logged to calls, every body
# sent is kept as body_<n>.json, and FAKE_FAIL="<METHOD>_<path>" answers that
# call with a 500.
cat > "$WORK/bin/curl" <<'FAKE'
#!/bin/bash
set -euo pipefail
method=GET out="" body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -o) out="$2"; shift ;;
    -d) body="$2"; shift ;;
    -H|-w|--data-urlencode|--data-binary) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  https://login.microsoftonline.com/*) echo '{"access_token":"fake-token"}'; exit 0 ;;
  https://manage.devcenter.microsoft.com/v1.0/my/applications/*)
    path="${url#https://manage.devcenter.microsoft.com/v1.0/my/applications/}"
    key="${method}_${path//\//_}" ;;
  *) key="${method}_blob" ;;
esac
echo "$key" >> "$FAKE_STATE/calls"
code=200 response=""
if [ -n "$body" ]; then
  n=$(wc -l < "$FAKE_STATE/calls" | tr -d ' ')
  printf '%s' "$body" > "$FAKE_STATE/body_$n.json"
fi
if [ "${FAKE_FAIL:-}" = "$key" ]; then
  code=500 response='{"code":"InternalError"}'
elif [ -f "$FAKE_STATE/$key.json" ]; then
  response=$(cat "$FAKE_STATE/$key.json")
elif [ "$method" = "PUT" ]; then
  response="$body"
elif [ "$method" = "DELETE" ]; then
  code=204
elif [[ "$key" == *_commit ]]; then
  response='{"status":"CommitStarted"}'
else
  code=404 response='{"code":"NotFound"}'
fi
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then printf '%s' "$response" > "$out"; fi
printf '%s' "$code"
FAKE
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export STORE_TENANT_ID=tenant STORE_CLIENT_ID=client STORE_CLIENT_SECRET=secret STORE_APP_ID=APP
export PRICING_FILE=store/pricing.json

# A package whose manifest says 2.6.1.0, laid out the way msix:create writes it.
mkdir -p "$WORK/msix"
cat > "$WORK/msix/AppxManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
  <Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
    <Identity Name="9891PhantomDevs.WSL2Manager" Version="2.6.1.0"
              Publisher="CN=publisher" ProcessorArchitecture="x64" />
    <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.22621.2861" /></Dependencies>
  </Package>
XML
MSIX="$WORK/wsl2-distro-manager-v2.6.1-unsigned.msix"
( cd "$WORK/msix" && zip -q "$MSIX" AppxManifest.xml )

pricing='"pricing":{"trialPeriod":"NoFreeTrial","marketSpecificPricings":{},"sales":[],"priceId":"Free","isAdvancedPricingModel":true}'
submission() { # id status version
  printf '{"id":"%s","status":"%s","fileUploadUrl":"https://blob.example/upload/%s",%s,"listings":{"de-de":{"baseListing":{"description":"Handgeschrieben"}}},"applicationPackages":[{"fileName":"old.msix","fileStatus":"Uploaded","version":"%s"}]}' \
    "$1" "$2" "$1" "$pricing" "$3"
}

# scenario NAME APP_JSON: fresh state, the app resource set; then run.
scenario() {
  NAME="$1"
  export FAKE_STATE="$WORK/state-$NAME"
  rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"; : > "$FAKE_STATE/calls"
  printf '%s' "$2" > "$FAKE_STATE/GET_APP.json"
}
serve() { printf '%s' "$2" > "$FAKE_STATE/$1.json"; }
run() {
  export GITHUB_ACTIONS=true GITHUB_OUTPUT="$FAKE_STATE/output" GITHUB_STEP_SUMMARY="$FAKE_STATE/summary"
  set +e
  "$SCRIPT" "$MSIX" > "$FAKE_STATE/stdout" 2> "$FAKE_STATE/stderr"
  STATUS=$?
  set -e
}
fail() {
  echo "FAIL [$NAME] $1" >&2
  echo "--- calls" >&2; cat "$FAKE_STATE/calls" >&2
  echo "--- stdout" >&2; cat "$FAKE_STATE/stdout" >&2
  echo "--- stderr" >&2; cat "$FAKE_STATE/stderr" >&2
  exit 1
}
expect_status() { [ "$STATUS" = "$1" ] || fail "exit $STATUS, expected $1"; }
expect_result() { grep -qx "result=$1" "$FAKE_STATE/output" 2>/dev/null || fail "result is not $1"; }
called()     { grep -qx "$1" "$FAKE_STATE/calls" || fail "$1 was not called"; }
not_called() { ! grep -q "$1" "$FAKE_STATE/calls" || fail "$1 was called"; }
read_only()  { not_called '^POST_'; not_called '^PUT_'; not_called '^DELETE_'; }
# The body of the last call matching $1.
sent() {
  local n; n=$(grep -nx "$1" "$FAKE_STATE/calls" | tail -n 1 | cut -d: -f1)
  cat "$FAKE_STATE/body_$n.json"
}
ok() { echo "ok   $1"; }

LIVE_ONLY='{"id":"APP","lastPublishedApplicationSubmission":{"id":"83"}}'
WITH_PENDING='{"id":"APP","lastPublishedApplicationSubmission":{"id":"83"},"pendingApplicationSubmission":{"id":"84"}}'

scenario publish "$LIVE_ONLY"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
serve POST_APP_submissions "$(submission 90 PendingCommit 2.6.0.0)"
run
expect_status 0; expect_result published
called POST_APP_submissions; called PUT_blob; called POST_APP_submissions_90_commit; not_called DELETE_
sent PUT_APP_submissions_90 | jq -e '[.applicationPackages[] | {fileName, fileStatus}]
  == [{fileName:"old.msix",fileStatus:"PendingDelete"},
      {fileName:"wsl2-distro-manager-v2.6.1-unsigned.msix",fileStatus:"PendingUpload"}]' >/dev/null \
  || fail "the package swap is wrong"
ok "nothing pending, Store behind: a new submission is created and committed"

scenario adopt "$WITH_PENDING"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
serve GET_APP_submissions_84 "$(submission 84 PendingCommit 2.6.0.0)"
run
expect_status 0; expect_result adopted
not_called POST_APP_submissions$; not_called DELETE_
called PUT_APP_submissions_84; called PUT_blob; called POST_APP_submissions_84_commit
sent PUT_APP_submissions_84 | jq -e '.listings["de-de"].baseListing.description == "Handgeschrieben"
  and ([.applicationPackages[] | select(.fileStatus == "PendingUpload") | .fileName]
       == ["wsl2-distro-manager-v2.6.1-unsigned.msix"])' >/dev/null \
  || fail "the draft's listings or packages were not carried correctly"
ok "a pending draft is adopted: packages swapped, listings untouched, committed"

scenario adopt-fails "$WITH_PENDING"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
serve GET_APP_submissions_84 "$(submission 84 PendingCommit 2.6.0.0)"
FAKE_FAIL=PUT_blob run
expect_status 1; not_called DELETE_; not_called _commit
grep -q "Leaving draft submission 84 in place" "$FAKE_STATE/stderr" || fail "no word about the draft"
ok "a failure while adopting a draft leaves the draft alone"

scenario new-fails "$LIVE_ONLY"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
serve POST_APP_submissions "$(submission 90 PendingCommit 2.6.0.0)"
FAKE_FAIL=PUT_blob run
expect_status 1; called DELETE_APP_submissions_90; not_called _commit
ok "a failure on a submission this run created removes it"

for status in PreProcessing Certification CommitStarted Release; do
  scenario "defer-$status" "$WITH_PENDING"
  serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
  serve GET_APP_submissions_84 "$(submission 84 "$status" 2.6.0.0)"
  run
  expect_status 0; expect_result deferred; read_only
  grep -q '^::warning' "$FAKE_STATE/stdout" || fail "no warning annotation"
  grep -q 'Deferred: submission 84' "$FAKE_STATE/summary" || fail "no job summary"
done
ok "an older release in flight defers without failing, writing nothing"

scenario already-submitted "$WITH_PENDING"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
serve GET_APP_submissions_84 "$(submission 84 Certification 2.6.1.0)"
run
expect_status 0; expect_result already-submitted; read_only
ok "this version already in certification is a no-op"

scenario up-to-date "$LIVE_ONLY"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.1.0)"
run
expect_status 0; expect_result up-to-date; read_only
ok "this version already live is a no-op"

scenario newer-live "$WITH_PENDING"
serve GET_APP_submissions_83 "$(submission 83 Published 2.10.0.0)"
serve GET_APP_submissions_84 "$(submission 84 PendingCommit 2.10.0.0)"
run
expect_status 0; expect_result up-to-date; read_only
ok "versions compare numerically (2.10 is newer than 2.6.1), and a draft is left alone then"

for status in CertificationFailed CommitFailed; do
  scenario "refuse-$status" "$WITH_PENDING"
  serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
  serve GET_APP_submissions_84 "$(submission 84 "$status" 2.6.0.0)"
  run
  expect_status 1; read_only
done
ok "a failed pending submission is refused and left alone"

scenario dry-run-draft "$WITH_PENDING"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.0.0)"
serve GET_APP_submissions_84 "$(submission 84 PendingCommit 2.6.0.0)"
DRY_RUN=1 run
expect_status 0; expect_result dry-run; read_only
ok "a dry run never writes to a draft it did not create"

scenario dry-run "$LIVE_ONLY"
serve GET_APP_submissions_83 "$(submission 83 Published 2.6.1.0)"
serve POST_APP_submissions "$(submission 90 PendingCommit 2.6.1.0)"
serve GET_APP_submissions_90 "$(submission 90 PendingCommit 2.6.1.0)"
DRY_RUN=1 run
expect_status 0; expect_result dry-run
called PUT_APP_submissions_90; called DELETE_APP_submissions_90; not_called PUT_blob; not_called _commit
ok "a dry run still proves the pricing when the version is already live"

echo "all publish_store checks passed"
