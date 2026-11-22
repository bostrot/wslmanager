// Turns a *verified* Stripe Checkout session into a licence row — or, when
// the run came from the Manual Trigger, the details Eric typed into the
// "Manual request" node.
//
// Stripe path: the event body that reached the webhook is not trusted. The
// previous node re-fetched the session straight from the Stripe API using our
// own secret key, and the IF before this one dropped anything that is not
// actually paid. So everything below reads from the re-fetched session, never
// from the posted payload. The node right before this one looked the session
// up in the licence table: a row that already exists means Stripe delivered
// this event before (it retries on anything but a 2xx) and the customer may
// already hold that key — so it is kept, never rotated.
//
// Manual path: someone wrote in with an old licence (pre-Stripe, lost, or
// otherwise unusable) and needs a fresh key — or bought a Team plan by email.
// There is no Stripe session, so the row gets a synthetic session id, a
// brand-new key, and the normal licence email goes out. Any old row that
// customer has is left untouched; deactivate it by hand in the data table if
// it should stop validating.
//
// Three plans: `pro` (one seat, perpetual), `commercial` (the purchased seats,
// perpetual) and `team` (the purchased seats, a yearly subscription — the row
// expires, and "Team change" moves the date on every paid renewal).

// Crockford-ish alphabet: no I, O, 0 or 1, so a key read off a screen and
// typed into the app cannot be ambiguous.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function block(n) {
  let bytes = null;
  try {
    bytes = globalThis.crypto.getRandomValues(new Uint8Array(n));
  } catch (e) {
    bytes = null;
  }
  let out = '';
  for (let i = 0; i < n; i++) {
    const v = bytes ? bytes[i] : Math.floor(Math.random() * 256);
    out += ALPHABET[v % ALPHABET.length];
  }
  return out;
}
function newKey() {
  return ['WSLM', block(5), block(5), block(5), block(5)].join('-');
}
// Perpetual. The validator compares against this date, so a null would read
// as expired rather than as "never expires".
const NEVER = '2099-12-31T00:00:00.000Z';

// A Team licence is billed yearly. The session does not say when the first
// period ends, so the row is written a year ahead plus a grace period; the
// first renewal invoice then moves it to the period Stripe actually billed.
// The grace outlasts Stripe's retries of a failed card (about two weeks), so
// a renewal that needs a second attempt never locks a team out.
const TEAM_TERM_DAYS = 365;
const TEAM_GRACE_DAYS = 14;
function teamExpiry(now) {
  return new Date(
    now.getTime() + (TEAM_TERM_DAYS + TEAM_GRACE_DAYS) * 86400000
  ).toISOString();
}

const PER_SEAT = ['commercial', 'team'];

// The plan a session was sold as: the Payment Link's `tier` metadata, which
// Stripe copies onto the session, or failing that the price's lookup key
// (`team_seat_year`, `commercial_seat`, `pro_windows`, `pro_macos`).
function tierOf(session) {
  const meta = String((session.metadata && session.metadata.tier) || '')
    .trim()
    .toLowerCase();
  if (meta) return meta;
  const items = (session.line_items && session.line_items.data) || [];
  const keys = Array.isArray(items)
    ? items.map((i) => String((i && i.price && i.price.lookup_key) || ''))
    : [];
  if (keys.some((k) => k.startsWith('team'))) return 'team';
  if (keys.some((k) => k.startsWith('commercial'))) return 'commercial';
  return 'pro';
}

function manualLicence(input, now) {
  const email = String(input.email || '').trim();
  if (!email || !email.includes('@')) {
    throw new Error('Manual request: fill in the customer\'s email address first');
  }
  const asked = String(input.plan || 'pro').trim().toLowerCase();
  const tier = PER_SEAT.includes(asked) ? asked : 'pro';
  const seats = PER_SEAT.includes(tier)
    ? Math.max(1, Math.floor(Number(input.seats)) || 1)
    : 1;
  const stamp = now.toISOString().slice(0, 10).replace(/-/g, '');
  return {
    license_key: newKey().toLowerCase(),
    resent: false,
    email,
    company: PER_SEAT.includes(tier) ? String(input.company || '').trim() : '',
    stripe_id: '',
    // Unique, so the upsert in Save licence inserts a new row, and
    // recognisable in the table as a hand-issued replacement.
    session_id: `manual_${stamp}_${block(8).toLowerCase()}`,
    plan: tier,
    seats,
    // A hand-issued Team licence has no subscription to renew it: it runs
    // for the year and is extended by hand in the data table.
    expires: tier === 'team' ? teamExpiry(now) : NEVER,
  };
}

function sessionLicence(session, existing, now) {
  // Seats come from the purchased quantity, so a promo code cannot skew the
  // count the way dividing amount_total by the unit price would.
  let seats = 1;
  try {
    const items = session.line_items && session.line_items.data;
    if (Array.isArray(items) && items.length) {
      seats = items.reduce((n, i) => n + (i.quantity || 0), 0) || 1;
    }
  } catch (e) {
    seats = 1;
  }

  const key = existing.license_key ? String(existing.license_key) : newKey();
  const tier = tierOf(session);
  const details = session.customer_details || {};

  // A redelivered event keeps the date the row already carries: by then a
  // renewal may have moved it, and this must not move it back.
  const kept = existing.license_key && existing.expires
    ? new Date(existing.expires)
    : null;
  const expires = tier !== 'team'
    ? NEVER
    : kept && !Number.isNaN(kept.getTime())
      ? kept.toISOString()
      : teamExpiry(now);

  return {
    // Stored lower-case so lookups are case-insensitive; the website and the
    // app upper-case it for display.
    license_key: key.toLowerCase(),
    // Whether this event had been seen before; the email is only sent once.
    resent: !!existing.license_key,
    email: session.customer_email || details.email || '',
    company: PER_SEAT.includes(tier)
      ? (details.business_name || details.name || '')
      : '',
    stripe_id: session.customer || '',
    session_id: session.id,
    plan: tier,
    seats: PER_SEAT.includes(tier) ? seats : 1,
    expires,
  };
}

// --- n8n Code node entry point -------------------------------------------
// Present only inside n8n; under `node` this falls through to the export.
if (typeof $input !== 'undefined') {
  const input = $input.first().json || {};
  if (input.source === 'manual') {
    return [{ json: manualLicence(input, new Date()) }];
  }
  const session = $('Re-fetch session').item.json;
  return [{ json: sessionLicence(session, input, new Date()) }];
}

module.exports = {
  manualLicence,
  sessionLicence,
  tierOf,
  teamExpiry,
  newKey,
  NEVER,
  TEAM_TERM_DAYS,
  TEAM_GRACE_DAYS,
};
