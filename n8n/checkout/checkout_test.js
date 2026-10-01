// node --test n8n/checkout/
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const build = require('./build_licence.js');
const team = require('./team_change.js');
const { compose } = require('./compose_email.js');

const NOW = new Date('2026-10-01T12:00:00.000Z');
const DAY = 86400000;

function session(overrides) {
  return Object.assign({
    id: 'cs_live_1',
    payment_status: 'paid',
    customer: 'cus_1',
    customer_email: null,
    customer_details: { email: 'buyer@example.com', name: 'Buyer', business_name: 'Buyer GmbH' },
    metadata: { tier: 'pro', platform: 'windows' },
    line_items: { data: [{ quantity: 1, price: { lookup_key: 'pro_windows' } }] },
  }, overrides);
}

test('a Pro session is one perpetual seat, as before', () => {
  const row = build.sessionLicence(session(), {}, NOW);
  assert.equal(row.plan, 'pro');
  assert.equal(row.seats, 1);
  assert.equal(row.expires, build.NEVER);
  assert.equal(row.company, '');
  assert.equal(row.resent, false);
  assert.match(row.license_key, /^wslm-[a-z2-9]{5}(-[a-z2-9]{5}){3}$/);
  assert.equal(row.email, 'buyer@example.com');
});

test('a Commercial session keeps its purchased seats and never expires', () => {
  const row = build.sessionLicence(session({
    metadata: { tier: 'commercial', platform: 'all' },
    line_items: { data: [{ quantity: 4, price: { lookup_key: 'commercial_seat' } }] },
  }), {}, NOW);
  assert.equal(row.plan, 'commercial');
  assert.equal(row.seats, 4);
  assert.equal(row.expires, build.NEVER);
  assert.equal(row.company, 'Buyer GmbH');
});

test('a Team session has its seats and expires a year and the grace ahead', () => {
  const row = build.sessionLicence(session({
    mode: 'subscription',
    subscription: 'sub_1',
    metadata: { tier: 'team', platform: 'all' },
    line_items: { data: [{ quantity: 7, price: { lookup_key: 'team_seat_year' } }] },
  }), {}, NOW);
  assert.equal(row.plan, 'team');
  assert.equal(row.seats, 7);
  assert.equal(row.company, 'Buyer GmbH');
  assert.equal(new Date(row.expires).getTime() - NOW.getTime(), 379 * DAY);
  assert.equal(build.teamExpiry(NOW), row.expires);
});

test('without link metadata the price lookup key names the plan', () => {
  const bare = (key, quantity) => session({
    metadata: {},
    line_items: { data: [{ quantity, price: { lookup_key: key } }] },
  });
  assert.equal(build.tierOf(bare('team_seat_year', 3)), 'team');
  assert.equal(build.sessionLicence(bare('team_seat_year', 3), {}, NOW).seats, 3);
  assert.equal(build.tierOf(bare('commercial_seat', 2)), 'commercial');
  assert.equal(build.tierOf(bare('pro_macos', 1)), 'pro');
  assert.equal(build.tierOf(session({ metadata: null, line_items: null })), 'pro');
  // Metadata, when present, wins over the key.
  assert.equal(build.tierOf(session({ metadata: { tier: 'Team' } })), 'team');
});

test('a redelivered event keeps the key and a date a renewal already moved', () => {
  const renewed = '2028-10-15T00:00:00.000Z';
  const existing = { license_key: 'wslm-aaaaa-bbbbb-ccccc-ddddd', expires: renewed };
  const row = build.sessionLicence(session({
    metadata: { tier: 'team' },
    line_items: { data: [{ quantity: 2 }] },
  }), existing, NOW);
  assert.equal(row.license_key, existing.license_key);
  assert.equal(row.resent, true);
  assert.equal(row.expires, renewed);
  // A row with an unreadable date falls back to the fresh term.
  const odd = build.sessionLicence(session({ metadata: { tier: 'team' } }),
    { license_key: 'wslm-x', expires: 'not a date' }, NOW);
  assert.equal(odd.expires, build.teamExpiry(NOW));
  // Pro stays perpetual whatever the row said.
  assert.equal(build.sessionLicence(session(), { license_key: 'wslm-x', expires: renewed }, NOW).expires, build.NEVER);
});

test('a hand-issued licence can be a Team one, for a sale made by email', () => {
  const row = build.manualLicence({ source: 'manual', email: ' lead@example.com ', plan: 'Team', seats: 12, company: 'Acme' }, NOW);
  assert.equal(row.plan, 'team');
  assert.equal(row.seats, 12);
  assert.equal(row.company, 'Acme');
  assert.equal(row.email, 'lead@example.com');
  assert.equal(row.expires, build.teamExpiry(NOW));
  assert.match(row.session_id, /^manual_20261001_[a-z2-9]{8}$/);

  const pro = build.manualLicence({ email: 'a@b.c', plan: 'whatever', seats: 9, company: 'x' }, NOW);
  assert.deepEqual([pro.plan, pro.seats, pro.company, pro.expires], ['pro', 1, '', build.NEVER]);
  const commercial = build.manualLicence({ email: 'a@b.c', plan: 'commercial', seats: 0 }, NOW);
  assert.deepEqual([commercial.plan, commercial.seats, commercial.expires], ['commercial', 1, build.NEVER]);
  assert.throws(() => build.manualLicence({ email: 'nope' }, NOW), /email address/);
});

// --- renewals and cancellations ------------------------------------------

const PERIOD_END = Math.floor(new Date('2027-10-01T12:00:00.000Z').getTime() / 1000);

function invoice(overrides) {
  return Object.assign({
    object: 'invoice',
    id: 'in_1',
    status: 'paid',
    customer: 'cus_1',
    subscription: 'sub_1',
    lines: { data: [{ period: { start: PERIOD_END - 31536000, end: PERIOD_END } }] },
  }, overrides);
}

function teamRow(overrides) {
  return Object.assign({
    id: 11, plan: 'team', stripe_id: 'cus_1', active: true, seats: 5,
    expires: '2026-10-15T12:00:00.000Z',
  }, overrides);
}

test('a paid subscription invoice renews until the period it billed, plus the grace', () => {
  const d = team.decide(invoice());
  assert.equal(d.action, 'renew');
  assert.equal(d.customer, 'cus_1');
  assert.equal(new Date(d.until).getTime(), (PERIOD_END + 14 * 86400) * 1000);
  // The subscription sits under `parent` on newer API versions.
  const newer = invoice({ subscription: undefined, parent: { subscription_details: { subscription: 'sub_1' } } });
  assert.equal(team.decide(newer).action, 'renew');
  // The latest line wins when an invoice has several.
  const two = invoice({ lines: { data: [{ period: { end: PERIOD_END - 999 } }, { period: { end: PERIOD_END } }] } });
  assert.equal(team.decide(two).until, d.until);
});

test('anything that is not a paid subscription invoice or an ended subscription is ignored', () => {
  assert.equal(team.decide(invoice({ status: 'open' })).action, 'none');
  assert.equal(team.decide(invoice({ subscription: null })).action, 'none', 'a one-off invoice');
  assert.equal(team.decide(invoice({ lines: { data: [] } })).action, 'none');
  assert.equal(team.decide(invoice({ customer: null })).action, 'none');
  assert.equal(team.decide({ object: 'subscription', status: 'active', customer: 'cus_1' }).action, 'none');
  assert.equal(team.decide({ object: 'checkout.session', customer: 'cus_1' }).action, 'none');
  for (const junk of [null, undefined, 'x', 42, {}, { error: { message: 'No such invoice' } }]) {
    assert.equal(team.decide(junk).action, 'none');
  }
  assert.deepEqual(team.changes([teamRow()], team.decide(null)), []);
});

test('a renewal touches only the customer\'s Team rows, revives a lapsed one, never shortens', () => {
  const d = team.decide(invoice());
  const rows = [
    teamRow({ id: 1, active: false, expires: '2026-09-01T00:00:00.000Z' }),
    { id: 2, plan: 'pro', stripe_id: 'cus_1', active: true, expires: build.NEVER },
    { id: 3, plan: 'commercial', stripe_id: 'cus_1', active: true, expires: build.NEVER },
    teamRow({ id: 4, stripe_id: 'cus_other' }),
    teamRow({ id: 5, expires: '2029-01-01T00:00:00.000Z' }),
    { plan: 'team', stripe_id: 'cus_1' },
    {},
  ];
  assert.deepEqual(team.changes(rows, d), [
    { row_id: 1, active: true, expires: d.until },
    { row_id: 5, active: true, expires: '2029-01-01T00:00:00.000Z' },
  ]);
  // A short invoice (a seat added mid-year) must not cut the year short.
  const short = team.decide(invoice({ lines: { data: [{ period: { end: Math.floor(NOW.getTime() / 1000) } }] } }));
  assert.equal(team.changes([teamRow({ expires: '2027-06-01T00:00:00.000Z' })], short)[0].expires, '2027-06-01T00:00:00.000Z');
});

test('an ended subscription stops the Team rows and nothing else', () => {
  const d = team.decide({ object: 'subscription', id: 'sub_1', status: 'canceled', customer: { id: 'cus_1' } });
  assert.deepEqual(d, { action: 'cancel', customer: 'cus_1' });
  const out = team.changes([
    teamRow({ id: 1 }),
    { id: 2, plan: 'pro', stripe_id: 'cus_1', active: true },
  ], d);
  assert.deepEqual(out, [{ row_id: 1, active: false, expires: '2026-10-15T12:00:00.000Z' }]);
});

// --- the email -------------------------------------------------------------

test('the Team email says seats, renewal and until when; the others are unchanged', () => {
  const mail = compose({ license_key: 'wslm-a', plan: 'team', seats: 3, email: 'lead@example.com', session_id: 'cs_1', expires: '2027-10-15T00:00:00.000Z' });
  assert.equal(mail.subject, 'Your WSL Manager Team licence key');
  assert.match(mail.html, /3 seats, renewing every year \(the current period runs until 2027-10-15\)/);
  assert.match(mail.html, /newest activation wins/);
  assert.match(mail.text, /\(3 seats, renews yearly, current period until 2027-10-15\)/);
  assert.equal(mail.skip, false);
  assert.doesNotMatch(mail.html, /perpetual/);

  const pro = compose({ license_key: 'wslm-a', plan: 'pro', seats: 1, email: 'a@b.c', session_id: 'cs_2', expires: build.NEVER });
  assert.equal(pro.subject, 'Your WSL Manager Pro licence key');
  assert.match(pro.html, /Your licence is perpetual/);
  assert.equal(pro.text.split('\n')[0], 'Thank you for buying WSL Manager Pro.');

  const commercial = compose({ license_key: 'wslm-a', plan: 'commercial', seats: 1, email: 'a@b.c', session_id: 'cs_3', expires: build.NEVER, resent: true });
  assert.match(commercial.html, /1 seat, perpetual, no renewal/);
  assert.equal(commercial.skip, true, 'a redelivery sends nothing');
  assert.equal(compose({ license_key: 'k', plan: 'team', seats: 2, email: '', session_id: 's' }).skip, true);
});

// --- the nodes as n8n runs them ---------------------------------------------

function runNode(file, { input, nodes }) {
  const src = fs.readFileSync(path.join(__dirname, file), 'utf8');
  const $input = { first: () => ({ json: input[0] }), all: () => input.map((json) => ({ json })) };
  const $ = (name) => {
    if (!(name in nodes)) throw new Error(`node ${name} has not run`);
    return { item: { json: nodes[name] }, first: () => ({ json: nodes[name] }) };
  };
  return new Function('$input', '$', 'module', src)($input, $, { exports: {} });
}

test('Build licence runs inside n8n for a session and for a manual request', () => {
  const [stripe] = runNode('build_licence.js', {
    input: [{}],
    nodes: { 'Re-fetch session': session({ metadata: { tier: 'team' }, line_items: { data: [{ quantity: 2 }] } }) },
  });
  assert.equal(stripe.json.plan, 'team');
  assert.equal(stripe.json.seats, 2);
  // The manual branch returns before the Stripe lookup: that node never ran.
  const [manual] = runNode('build_licence.js', { input: [{ source: 'manual', email: 'a@b.c', plan: 'team', seats: 3 }], nodes: {} });
  assert.equal(manual.json.plan, 'team');
});

test('Team change runs inside n8n over the rows the table returned', () => {
  const out = runNode('team_change.js', {
    input: [teamRow({ id: 9 }), { id: 10, plan: 'pro', stripe_id: 'cus_1' }],
    nodes: { 'Re-fetch object': invoice() },
  });
  assert.equal(out.length, 1);
  assert.equal(out[0].json.row_id, 9);
  // No rows at all (alwaysOutputData hands over one empty item): nothing to do.
  assert.deepEqual(runNode('team_change.js', { input: [{}], nodes: { 'Re-fetch object': invoice() } }), []);
});

test('the workflow export embeds these exact files and routes the events', () => {
  const wf = JSON.parse(fs.readFileSync(path.join(__dirname, 'wsl-manager-checkout.workflow.json'), 'utf8'));
  const node = (name) => wf.nodes.find((n) => n.name === name);
  for (const [name, file] of [
    ['Build licence', 'build_licence.js'],
    ['Team change', 'team_change.js'],
    ['Compose licence email', 'compose_email.js'],
  ]) {
    assert.ok(node(name), `${name} node present`);
    assert.equal(node(name).parameters.jsCode, fs.readFileSync(path.join(__dirname, file), 'utf8'), name);
  }
  const next = (name, output = 0) => (wf.connections[name].main[output] || []).map((c) => c.node);
  assert.deepEqual(next('Stripe events'), ['Event type']);
  assert.deepEqual(next('Event type', 0), ['Re-fetch session']);
  assert.deepEqual(next('Event type', 1), ['Re-fetch object']);
  assert.deepEqual(next('Re-fetch object'), ['Team rows']);
  assert.deepEqual(next('Team rows'), ['Team change']);
  assert.deepEqual(next('Team change'), ['Apply team change']);
  // The checkout path itself is as it was.
  assert.deepEqual(next('Re-fetch session'), ['Actually paid']);
  assert.deepEqual(next('Existing licence'), ['Build licence']);
  // The Set node holds whichever customer was last sent a replacement key;
  // the public export must not.
  const typed = node('Manual request').parameters.assignments.assignments
    .find((a) => a.name === 'email').value;
  assert.equal(typed, 'customer@example.com');
});
