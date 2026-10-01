// What a Team subscription's later life does to its licence row.
//
// Two Stripe events reach this node, both re-fetched from the Stripe API by
// the node before the last (the posted payload is never trusted):
//
//   invoice.paid                   the subscription was billed for another
//                                  year: the row runs until that period
//                                  ends, plus the grace, and is active again
//                                  if it had lapsed.
//   customer.subscription.deleted  the subscription is over: the row stops
//                                  validating.
//
// A renewal that *fails* sends nothing here and needs nothing done: the row
// keeps the date its last paid invoice set and lapses on its own once Stripe
// has given up retrying the card.
//
// The rows are the customer's (the node before this one fetched them by
// `stripe_id`), and only the ones whose plan is `team` are ever touched — a
// Pro or Commercial key the same customer bought is perpetual and stays so.
// The licence table has no subscription column, so a customer with two Team
// subscriptions has both rows follow either one; that is what the licence
// server (wslmanager-license) fixes, and why this is the interim.

// Same grace as "Build licence": longer than Stripe retries a failed card.
const TEAM_GRACE_DAYS = 14;

const NONE = { action: 'none' };

function customerOf(object) {
  const c = object.customer;
  if (typeof c === 'string') return c;
  return c && typeof c.id === 'string' ? c.id : '';
}

// The subscription an invoice bills, wherever the API version put it.
function subscriptionOf(invoice) {
  const parent = invoice.parent && invoice.parent.subscription_details;
  const sub = invoice.subscription || (parent && parent.subscription);
  if (typeof sub === 'string') return sub;
  return sub && typeof sub.id === 'string' ? sub.id : '';
}

/**
 * What a re-fetched Stripe object asks for: `renew` until a date, `cancel`,
 * or nothing.
 */
function decide(object) {
  if (!object || typeof object !== 'object') return NONE;
  const customer = customerOf(object);
  if (!customer) return NONE;

  if (object.object === 'invoice') {
    // A one-off invoice (a Commercial purchase sends one too) renews nothing.
    if (object.status !== 'paid' || !subscriptionOf(object)) return NONE;
    const lines = (object.lines && object.lines.data) || [];
    const ends = (Array.isArray(lines) ? lines : [])
      .map((l) => l && l.period && Number(l.period.end))
      .filter((n) => Number.isFinite(n) && n > 0);
    if (!ends.length) return NONE;
    const until = new Date(
      (Math.max(...ends) + TEAM_GRACE_DAYS * 86400) * 1000
    ).toISOString();
    return { action: 'renew', customer, until };
  }

  if (object.object === 'subscription') {
    if (object.status !== 'canceled') return NONE;
    return { action: 'cancel', customer };
  }

  return NONE;
}

function iso(value) {
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/**
 * The updates to write: one per Team row, as `{row_id, active, expires}`.
 * A renewal never moves a date backwards — an invoice for a short period
 * (a proration, a seat added mid-year) must not cut the year short.
 */
function changes(rows, decision) {
  if (!decision || decision.action === 'none') return [];
  return (Array.isArray(rows) ? rows : [])
    .filter((r) => r && r.id !== undefined && r.id !== null)
    .filter((r) => String(r.plan || '').toLowerCase() === 'team')
    .filter((r) => !decision.customer || r.stripe_id === decision.customer)
    .map((r) => {
      const current = iso(r.expires);
      if (decision.action === 'cancel') {
        return { row_id: r.id, active: false, expires: current || decision.until || new Date(0).toISOString() };
      }
      const later = current && current > decision.until ? current : decision.until;
      return { row_id: r.id, active: true, expires: later };
    });
}

// --- n8n Code node entry point -------------------------------------------
// Present only inside n8n; under `node` this falls through to the export.
if (typeof $input !== 'undefined') {
  const object = $('Re-fetch object').first().json || {};
  const rows = $input.all().map((i) => i.json || {});
  return changes(rows, decide(object)).map((json) => ({ json }));
}

module.exports = { decide, changes, subscriptionOf, TEAM_GRACE_DAYS };
