#!/usr/bin/env bash
# Offline check of scripts/store_pricing.jq against the shape the API
# actually returned for this app on 2026-09-07 (priceId "Base", two markets
# NotAvailable, advanced pricing model). No network, no credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

CLONE='{"id":"1152921505701830657","pricing":{"trialPeriod":"NoFreeTrial","marketSpecificPricings":{"LB":"NotAvailable","EH":"NotAvailable","DE":"Tier1000"},"sales":[],"priceId":"Base","isAdvancedPricingModel":true},"visibility":"Public"}'
# The paid tiers, kept in store/pricing-paid.json for rolling the flip back.
OUT=$(jq --from-file scripts/store_pricing.jq --argjson pricing "$(jq -c . store/pricing-paid.json)" <<<"$CLONE")

check() {
  if jq -e "$2" <<<"$OUT" >/dev/null; then echo "ok   $1"; else echo "FAIL $1" >&2; jq .pricing <<<"$OUT" >&2; exit 1; fi
}
check "base tier comes from the file"                     '.pricing.priceId == "Tier1102"'
check "markets the clone cannot sell in stay unavailable" '.pricing.marketSpecificPricings.LB == "NotAvailable" and .pricing.marketSpecificPricings.EH == "NotAvailable"'
check "a stale clone override not in the file is dropped" '.pricing.marketSpecificPricings | has("DE") | not'
check "tier A market priced 14.99"                        '.pricing.marketSpecificPricings.CH == "Tier1112"'
check "tier C market priced 4.99"                         '.pricing.marketSpecificPricings.IN == "Tier1052"'
check "12 + 64 priced markets plus the 2 unavailable"     '(.pricing.marketSpecificPricings | length) == 78'
check "trial period, sales and model flag untouched"      '.pricing.trialPeriod == "NoFreeTrial" and .pricing.sales == [] and .pricing.isAdvancedPricingModel == true'
check "nothing outside pricing changed"                   '.id == "1152921505701830657" and .visibility == "Public"'
jq -e '.priceId | test("^Tier[0-9]+$")' store/pricing-paid.json >/dev/null && echo "ok   paid file base tier is a Tier id"
jq -e '[.marketSpecificPricings[]] | all(test("^Tier[0-9]+$"))' store/pricing-paid.json >/dev/null && echo "ok   every paid file override is a Tier id"
[ "$(jq '.marketSpecificPricings | length' store/pricing-paid.json)" = "76" ] && echo "ok   paid file lists 76 markets"

# What a release publishes now: the freemium flip, through the same merge. A
# base of Free with no overrides has to leave every market free — an override
# left behind would keep that market paid while the listing says free
# everywhere else.
[ "$(jq -r .priceId store/pricing.json)" = "Free" ] && echo "ok   the release file says Free"
[ "$(jq '.marketSpecificPricings | length' store/pricing.json)" = "0" ] && echo "ok   the release file carries no market override"
FREE=$(jq --from-file scripts/store_pricing.jq \
         --argjson pricing "$(jq -c . store/pricing.json)" <<<"$CLONE")
freecheck() {
  if jq -e "$2" <<<"$FREE" >/dev/null; then echo "ok   $1"; else echo "FAIL $1" >&2; jq .pricing <<<"$FREE" >&2; exit 1; fi
}
freecheck "the free file states Free, not an absent tier" '.pricing.priceId == "Free"'
freecheck "no market is left at a price"                  '[.pricing.marketSpecificPricings[]] | all(. == "NotAvailable")'
freecheck "markets the clone cannot sell in stay unavailable" '.pricing.marketSpecificPricings.LB == "NotAvailable" and .pricing.marketSpecificPricings.EH == "NotAvailable"'
freecheck "the paid overrides are gone"                   '.pricing.marketSpecificPricings | (has("CH") or has("IN")) | not'
freecheck "trial period, sales and model flag untouched"  '.pricing.trialPeriod == "NoFreeTrial" and .pricing.sales == [] and .pricing.isAdvancedPricingModel == true'

# The publisher's own guard, run as publish_store.sh runs it: the condition is
# lifted out of the script itself rather than copied, so the two cannot drift.
# The September incident was a pricing object with no base tier at all, and
# that must still be refused.
GUARD=$(sed -n 's/^  \(\[\[ "\$WANT_PRICE_ID" .*\]\]\) \\$/\1/p' scripts/publish_store.sh)
[ -n "$GUARD" ] || { echo "FAIL cannot find the priceId guard in scripts/publish_store.sh" >&2; exit 1; }
accepts() { WANT_PRICE_ID="$1" eval "$GUARD"; }
for value in Tier1102 Free; do
  accepts "$value" || { echo "FAIL the guard rejects \"$value\"" >&2; exit 1; }
done
for value in Base "" Tier NotAvailable free; do
  ! accepts "$value" || { echo "FAIL the guard would accept \"$value\"" >&2; exit 1; }
done
echo "ok   the guard takes a Tier id or Free and refuses Base, empty and the rest"

echo "all store pricing checks passed"
