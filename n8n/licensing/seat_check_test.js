// node --test n8n/licensing/
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const seat = require('./seat_check.js');
const { decide } = seat;

const NOW = new Date('2026-09-10T12:00:00.000Z');
const daysAgo = (n) => new Date(NOW.getTime() - n * 86400000).toISOString();

function row(overrides) {
  return Object.assign({
    id: 7,
    license_key: 'wslm-aaaaa-bbbbb-ccccc-ddddd',
    active: true,
    expires: '2099-12-31T00:00:00.000Z',
    plan: 'pro',
    is_trial: false,
    seats: 1,
    email: 'buyer@example.com',
    devices: null,
  }, overrides);
}

function req(query, headers) {
  return {
    query: Object.assign({ license: 'WSLM-AAAAA-BBBBB-CCCCC-DDDDD' }, query),
    headers: Object.assign({ 'user-agent': 'Dart/3.9 (dart:io)', 'x-forwarded-for': '203.0.113.5' }, headers),
    now: NOW,
  };
}

// Runs a sequence of requests against one row, threading the devices column
// through like the workflow does. Each step is [daysBeforeNow, query, headers].
function replay(startRow, steps) {
  let devices = startRow.devices;
  const out = [];
  for (const [days, query, headers] of steps) {
    const r = decide(Object.assign(req(query, headers), {
      row: row(Object.assign({}, startRow, { devices })),
      now: new Date(NOW.getTime() - days * 86400000),
    }));
    if (r.devices) devices = JSON.stringify(r.devices);
    out.push(r);
  }
  return { results: out, devices: JSON.parse(devices || '[]') };
}

test('unknown key is rejected without writing', () => {
  const r = decide(Object.assign(req({}), { row: {} }));
  assert.equal(r.valid, false);
  assert.equal(r.reason, 'unknown_key');
  assert.equal(r.response.valid, false);
  assert.equal(r.devices, null);
});

test('inactive and expired rows are rejected as before', () => {
  assert.equal(decide(Object.assign(req({}), { row: row({ active: false }) })).reason, 'inactive');
  assert.equal(decide(Object.assign(req({}), { row: row({ expires: '2020-01-01T00:00:00.000Z' }) })).reason, 'expired');
  // Unreadable date reads as expired, never as perpetual.
  assert.equal(decide(Object.assign(req({}), { row: row({ expires: null }) })).reason, 'expired');
});

test('legacy request without a device stays valid and is only noted', () => {
  const r = decide(Object.assign(req({}), { row: row() }));
  assert.equal(r.valid, true);
  assert.equal(r.response.valid, true);
  assert.equal(r.response.enforced, false);
  assert.equal(r.response.plan, 'pro');
  assert.equal(r.response.seats, 1);
  assert.equal(r.response.email, 'buyer@example.com');
  assert.deepEqual(r.devices.map((d) => [d.id, d.kind, d.hits]), [['ip:203.0.113.5', 'legacy', 1]]);
});

test('legacy entries never occupy a seat', () => {
  const { results } = replay(row(), [
    [10, {}, { 'x-forwarded-for': '198.51.100.1' }],
    [5, {}, { 'x-forwarded-for': '198.51.100.2' }],
    [0, { device: 'pc-a', action: 'activate' }],
  ]);
  assert.ok(results.every((r) => r.valid));
  assert.equal(results[2].response.seats_used, 1);
});

test('first activation takes the seat and re-validation keeps it', () => {
  const { results, devices } = replay(row(), [
    [20, { device: 'pc-a', action: 'activate' }],
    [6, { device: 'pc-a', action: 'revalidate' }],
  ]);
  assert.deepEqual(results.map((r) => r.reason), ['activate', 'revalidate']);
  assert.ok(results.every((r) => r.valid && r.response.enforced && r.response.device === 'pc-a'));
  assert.equal(devices.length, 1);
  assert.equal(devices[0].activated_at, daysAgo(20));
  assert.equal(devices[0].last_seen, daysAgo(6));
  assert.deepEqual(Object.keys(devices[0]).sort(), ['activated_at', 'first_seen', 'id', 'kind', 'last_seen'],
    'device entries hold the id and timestamps only, no address or user agent');
});

test('a second PC activating displaces the first, which is denied on re-validation', () => {
  const { results } = replay(row(), [
    [30, { device: 'pc-a', action: 'activate' }],
    [10, { device: 'pc-b', action: 'activate' }],
    [0, { device: 'pc-a', action: 'revalidate' }],
  ]);
  assert.equal(results[1].valid, true);
  assert.equal(results[2].valid, false);
  assert.equal(results[2].reason, 'seat_taken');
  assert.equal(results[2].response.seats_used, 1);
  assert.match(results[2].response.message, /another PC/);
});

test('the displaced PC gets Pro back by activating again, and the other one is then denied', () => {
  const { results, devices } = replay(row(), [
    [30, { device: 'pc-a', action: 'activate' }],
    [10, { device: 'pc-b', action: 'activate' }],
    [2, { device: 'pc-a', action: 'revalidate' }],
    [1, { device: 'pc-a', action: 'activate' }],
    [0, { device: 'pc-b', action: 'revalidate' }],
  ]);
  assert.deepEqual(results.map((r) => r.valid), [true, true, false, true, false]);
  const a = devices.find((d) => d.id === 'pc-a');
  assert.equal(a.denied_at, undefined, 'activation clears the denial marker');
  assert.equal(devices.find((d) => d.id === 'pc-b').denied_at, daysAgo(0));
});

test('re-validation from a never-seen device counts as activation', () => {
  const r = decide(Object.assign(req({ device: 'pc-new', action: 'revalidate' }), { row: row() }));
  assert.equal(r.valid, true);
  assert.equal(r.reason, 'activate');
});

test('a device that names no action is activating: the check fails open, never denies', () => {
  const { results } = replay(row(), [
    [30, { device: 'pc-a' }],
    [10, { device: 'pc-b' }],
    [0, { device: 'pc-a' }],
  ]);
  assert.deepEqual(results.map((r) => r.reason), ['activate', 'activate', 'activate']);
  assert.ok(results.every((r) => r.valid));
});

test('commercial seats admit that many PCs and displace the least recently activated', () => {
  const { results } = replay(row({ seats: 3, plan: 'commercial' }), [
    [40, { device: 'pc-1', action: 'activate' }],
    [30, { device: 'pc-2', action: 'activate' }],
    [20, { device: 'pc-3', action: 'activate' }],
    [10, { device: 'pc-4', action: 'activate' }],
    [1, { device: 'pc-1', action: 'revalidate' }],
    [0, { device: 'pc-2', action: 'revalidate' }],
  ]);
  assert.deepEqual(results.map((r) => r.valid), [true, true, true, true, false, true]);
  assert.equal(results[3].response.seats_used, 3);
});

test('seats is coerced: strings work, nonsense means one seat', () => {
  assert.equal(decide(Object.assign(req({}), { row: row({ seats: '2' }) })).response.seats, 2);
  assert.equal(decide(Object.assign(req({}), { row: row({ seats: 0 }) })).response.seats, 1);
  assert.equal(decide(Object.assign(req({}), { row: row({ seats: 'many' }) })).response.seats, 1);
});

test('a seat holder unseen for longer than the window frees its seat', () => {
  const { results } = replay(row(), [
    [seat.SEAT_WINDOW_DAYS + 5, { device: 'pc-a', action: 'activate' }],
    [seat.SEAT_WINDOW_DAYS + 1, { device: 'pc-b', action: 'activate' }],
    [0, { device: 'pc-a', action: 'revalidate' }],
  ]);
  // pc-b displaced pc-a, but pc-b has since gone quiet, so pc-a is back in.
  assert.equal(results[2].valid, true);
});

test('stale devices are pruned, holders never are', () => {
  const { devices } = replay(row(), [
    [seat.KEEP_DAYS + 10, { device: 'pc-old', action: 'activate' }],
    [seat.KEEP_DAYS + 5, {}, { 'x-forwarded-for': '198.51.100.9' }],
    [0, { device: 'pc-a', action: 'activate' }],
  ]);
  assert.deepEqual(devices.map((d) => d.id), ['pc-a']);
});

test('legacy entries are capped to the most recent few', () => {
  const steps = [];
  for (let i = 0; i < seat.MAX_LEGACY_ENTRIES + 7; i++) {
    steps.push([seat.MAX_LEGACY_ENTRIES + 7 - i, {}, { 'x-forwarded-for': '198.51.100.' + i }]);
  }
  const { devices } = replay(row(), steps);
  assert.equal(devices.length, seat.MAX_LEGACY_ENTRIES);
  assert.equal(devices[0].id, 'ip:198.51.100.' + (seat.MAX_LEGACY_ENTRIES + 6), 'newest first');
});

test('garbage in the devices column is treated as empty', () => {
  for (const junk of ['not json', '{"a":1}', '[1,2,{"id":3}]', 42]) {
    const r = decide(Object.assign(req({ device: 'pc-a', action: 'activate' }), { row: row({ devices: junk }) }));
    assert.equal(r.valid, true, String(junk));
    assert.equal(r.devices.length, 1);
  }
});

test('device ids are sanitised', () => {
  assert.equal(seat.normalizeDeviceId('  ABC-123_x:y.z  '), 'ABC-123_x:y.z');
  assert.equal(seat.normalizeDeviceId('has space'), null);
  assert.equal(seat.normalizeDeviceId('x'.repeat(65)), null);
  assert.equal(seat.normalizeDeviceId(''), null);
  assert.equal(seat.normalizeDeviceId(['a']), null);
  // An unusable device id falls back to the legacy path rather than failing.
  const r = decide(Object.assign(req({ device: '<script>' }), { row: row() }));
  assert.equal(r.valid, true);
  assert.equal(r.response.enforced, false);
});

test('client ip prefers the proxy headers in order and tolerates none', () => {
  assert.equal(seat.clientIp({ 'cf-connecting-ip': '1.1.1.1', 'x-real-ip': '2.2.2.2', 'x-forwarded-for': '3.3.3.3, 4.4.4.4' }), '1.1.1.1');
  assert.equal(seat.clientIp({ 'x-real-ip': '2.2.2.2', 'x-forwarded-for': '3.3.3.3, 4.4.4.4' }), '2.2.2.2');
  assert.equal(seat.clientIp({ 'x-forwarded-for': '3.3.3.3, 4.4.4.4' }), '3.3.3.3');
  assert.equal(seat.clientIp({}), 'unknown');
  assert.equal(seat.clientIp(undefined), 'unknown');
});

test('the workflow export embeds this exact file in its Code node', () => {
  const dir = __dirname;
  const src = fs.readFileSync(path.join(dir, 'seat_check.js'), 'utf8');
  const wf = JSON.parse(fs.readFileSync(path.join(dir, 'wsl-manager-licensing.workflow.json'), 'utf8'));
  const node = wf.nodes.find((n) => n.name === 'Seat check');
  assert.ok(node, 'Seat check node present');
  assert.equal(node.type, 'n8n-nodes-base.code');
  assert.equal(node.parameters.jsCode, src);
});
