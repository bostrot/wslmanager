# Checkout workflow

`wsl-manager-checkout.workflow.json` is the export of the **WSL Manager
Checkout** workflow on n8n: Stripe's webhook comes in at
`POST /webhook/wsl-manager/stripe-events`, a licence row goes into the
`wsl-manager-licenses` data table and the key goes out by email; the
website's success page polls `GET /webhook/wsl-manager/checkout`.

The three Code nodes live here as files, embedded verbatim in the export
(`node --test n8n/checkout/` fails if they drift):

| File | Node | What |
|---|---|---|
| `build_licence.js` | Build licence | A verified checkout session, or a manual request, as a licence row. |
| `team_change.js` | Team change | What a paid renewal or an ended subscription does to a Team row. |
| `compose_email.js` | Compose licence email | The licence email, HTML and text. |

## Plans

| Plan | Seats | Expires | Sold as |
|---|---|---|---|
| `pro` | 1 | never (`2099-12-31`) | one-time, `tier=pro` |
| `commercial` | the purchased quantity | never | one-time, `tier=commercial` |
| `team` | the purchased quantity | a year and 14 days from the sale, then whatever the last paid invoice billed, plus 14 days | yearly subscription, `tier=team` |

The plan is the Payment Link's `tier` metadata; without it, the price's
lookup key (`team_seat_year`, `commercial_seat`, `pro_*`). The validator in
`../licensing` already honours `seats` and `expires`, so a Team key needs
nothing there.

## Events

```
Stripe events (webhook)
  → Event type
      checkout.session.completed,
      checkout.session.async_payment_succeeded
        → Re-fetch session → Actually paid → Existing licence
        → Build licence → Save licence → Compose licence email → Send it?
      invoice.paid, customer.subscription.deleted
        → Re-fetch object (the invoice or the subscription, from Stripe)
        → Team rows (every row of that Stripe customer)
        → Team change → Apply team change (update by row id)
      anything else: stops
```

Nothing in a posted event is trusted on either branch: the object is read
back from the Stripe API with our own key first.

- **`invoice.paid`** on a subscription invoice moves the customer's Team
  rows to the end of the billed period plus 14 days and makes them active
  again. It never moves a date backwards, and a one-off invoice (a
  Commercial purchase sends one) is ignored.
- **`customer.subscription.deleted`** deactivates the customer's Team rows.
- A **failed renewal** needs nothing: the row keeps its date and lapses
  once Stripe has stopped retrying.
- Pro and Commercial rows of the same customer are never touched.

The Stripe webhook endpoint has to send those two events as well as
`checkout.session.completed`; `npm run stripe-prices -- --apply --webhook`
in the website repo adds them. Update the workflow *first*: the old one
sends every event to "Re-fetch session", which fails on an invoice.

## A Team sale made by email

Until the Team Payment Link exists the plan is sold by email. Open the
workflow, set the **Manual request** node to `plan = team`, the seat count,
the buyer's address and company, and execute **Manual: replacement key**.
The row runs for a year and 14 days; with no subscription behind it, it is
extended by hand in the data table.

## Limits, and why this is the interim

The licence table has no subscription column, so renewals and
cancellations are matched by Stripe customer: a customer holding two Team
subscriptions has both rows follow either one. The licence server
(`wslmanager-license`) stores the subscription on the licence and is where
this moves; it mounts the same webhook path, so the switch needs no change
in Stripe.

The export leaves out the address typed into **Manual request**, which on
the live workflow is whichever customer was last sent a replacement key.
