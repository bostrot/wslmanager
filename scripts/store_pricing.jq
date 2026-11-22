# Writes the repository's pricing (store/pricing.json, bound as $pricing) into a
# cloned submission's pricing object.
#
# Everything the clone knows that the file does not is kept: trial period, the
# deprecated sales array, the read-only isAdvancedPricingModel flag, and every
# market the clone marks "NotAvailable" — those are markets the app is not sold
# in at all, which is availability, not price, and the file never speaks to it.
# A market the file prices always wins over anything else the clone had for it.
.pricing = (
  (.pricing // {})
  | .priceId = $pricing.priceId
  | .marketSpecificPricings = (
      ((.marketSpecificPricings // {}) | with_entries(select(.value == "NotAvailable")))
      + ($pricing.marketSpecificPricings // {})
    )
)
