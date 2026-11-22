// Seat check for `GET /webhook/wsl-manager/validate`.
//
// This file is the body of the "Seat check" Code node in
// wsl-manager-licensing.workflow.json, verbatim — seat_check_test.js fails if
// the two drift. It also loads as a CommonJS module so the decision logic can
// be tested with plain `node --test`.
//
// A licence has `seats` (1 for Pro). Each device that activates takes a seat;
// when they are all taken the newest activation wins and the device it
// displaced is told `seat_taken` the next time it re-validates. So a key
// shared between two PCs keeps bouncing — whoever entered it last has Pro,
// the other one is asked to enter it again — while a customer who moves to a
// new PC just activates there and is never asked anything.
//
// The app tells activation and re-validation apart with `action=activate` /
// `action=revalidate` and names the PC with `device=<stable id>`. A request
// carrying neither is an app that predates seats: it stays valid exactly as
// before, and only its address is noted in `devices` so sharing is at least
// visible in the table. Requests that do name a device store just that id.

// A seat holder that has not checked in for this long has left: its seat is
// free again. The app re-validates every 14 days and keeps working offline
// for 60, so anything alive is seen well inside this window.
const SEAT_WINDOW_DAYS = 90;

// Devices unseen for this long are dropped from the row altogether.
const KEEP_DAYS = 180;

// Caps so the `devices` column cannot grow without bound.
const MAX_LEGACY_ENTRIES = 20;
const MAX_ENTRIES = 50;

const DAY_MS = 24 * 60 * 60 * 1000;

function parseDevices(raw) {
  if (Array.isArray(raw)) return raw.filter((d) => d && typeof d.id === 'string');
  if (typeof raw !== 'string' || !raw.trim()) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed)
      ? parsed.filter((d) => d && typeof d.id === 'string')
      : [];
  } catch (e) {
    return [];
  }
}

function clientIp(headers) {
  const h = headers || {};
  const forwarded = String(h['x-forwarded-for'] || '').split(',')[0].trim();
  return String(h['cf-connecting-ip'] || h['x-real-ip'] || forwarded || 'unknown');
}

// Whatever the app sends, stored as at most 64 safe characters.
function normalizeDeviceId(value) {
  if (typeof value !== 'string') return null;
  const id = value.trim();
  if (!id || id.length > 64 || !/^[A-Za-z0-9._:-]+$/.test(id)) return null;
  return id;
}

function seatCount(row) {
  const n = Math.floor(Number(row.seats));
  return Number.isFinite(n) && n >= 1 ? n : 1;
}

function isActive(row) {
  return row.active === true || row.active === 'true';
}

// Mirrors the old validator: a missing or unreadable date reads as expired,
// never as "never expires".
function isExpired(row, now) {
  const exp = Date.parse(row.expires);
  return Number.isNaN(exp) || now.getTime() >= exp;
}

function time(value) {
  const t = Date.parse(value);
  return Number.isNaN(t) ? 0 : t;
}

// The `seats` most recently activated devices that are still around.
function seatHolders(entries, seats, now) {
  const cutoff = now.getTime() - SEAT_WINDOW_DAYS * DAY_MS;
  return entries
    .filter((e) => e.kind === 'device' && time(e.last_seen) >= cutoff)
    .sort((a, b) => time(b.activated_at) - time(a.activated_at)
      || time(b.last_seen) - time(a.last_seen))
    .slice(0, seats);
}

function prune(entries, holders, now) {
  const keepAfter = now.getTime() - KEEP_DAYS * DAY_MS;
  const holderIds = new Set(holders.map((h) => h.id));
  const byRecency = (a, b) => time(b.last_seen) - time(a.last_seen);

  const devices = entries
    .filter((e) => e.kind === 'device')
    .filter((e) => holderIds.has(e.id) || time(e.last_seen) >= keepAfter);
  const legacy = entries
    .filter((e) => e.kind !== 'device')
    .filter((e) => time(e.last_seen) >= keepAfter)
    .sort(byRecency)
    .slice(0, MAX_LEGACY_ENTRIES);

  const kept = devices.concat(legacy);
  if (kept.length <= MAX_ENTRIES) return kept;
  const spare = kept
    .filter((e) => !holderIds.has(e.id))
    .sort(byRecency)
    .slice(0, Math.max(0, MAX_ENTRIES - holderIds.size));
  return kept.filter((e) => holderIds.has(e.id) || spare.includes(e));
}

function validResponse(row, extra) {
  return Object.assign({
    valid: true,
    plan: row.plan || 'pro',
    expires_at: row.expires || null,
    is_trial: row.is_trial === true || row.is_trial === 'true',
    seats: seatCount(row),
    email: typeof row.email === 'string' ? row.email : null,
  }, extra);
}

function invalid(reason, message) {
  return {
    valid: false,
    reason: reason,
    response: { valid: false, reason: reason, message: message },
    devices: null,
  };
}

// Pure: same inputs, same answer. `devices` in the result is the new value
// for the row's `devices` column, or null when nothing needs writing.
function decide(input) {
  const row = input.row || {};
  const query = input.query || {};
  const headers = input.headers || {};
  const now = input.now || new Date();
  const nowIso = now.toISOString();

  if (!row.license_key) {
    return invalid('unknown_key', 'No licence with this key.');
  }
  if (!isActive(row)) {
    return invalid('inactive', 'This licence has been deactivated.');
  }
  if (isExpired(row, now)) {
    return invalid('expired', 'This licence has expired.');
  }

  const seats = seatCount(row);
  const entries = parseDevices(row.devices);
  const ip = clientIp(headers);
  const ua = String(headers['user-agent'] || '');
  const deviceId = normalizeDeviceId(query.device);

  if (!deviceId) {
    // Pre-seat app: valid as always; note where the request came from.
    const id = 'ip:' + ip;
    let entry = entries.find((e) => e.id === id);
    if (!entry) {
      entry = { id: id, kind: 'legacy', first_seen: nowIso, hits: 0 };
      entries.push(entry);
    }
    entry.kind = 'legacy';
    entry.ip = ip;
    entry.ua = ua;
    entry.last_seen = nowIso;
    entry.hits = (Number(entry.hits) || 0) + 1;
    const holders = seatHolders(entries, seats, now);
    return {
      valid: true,
      reason: 'legacy',
      response: validResponse(row, { seats_used: holders.length, enforced: false }),
      devices: prune(entries, holders, now),
    };
  }

  let entry = entries.find((e) => e.kind === 'device' && e.id === deviceId);
  const known = !!entry;
  // A device this row has never seen is activating, whatever it says: the
  // app on it has the key, and denying would strand a PC that lost its
  // record but not its licence.
  const action = known && query.action === 'revalidate' ? 'revalidate' : 'activate';

  // Device entries carry the app's random per-install id and timestamps,
  // nothing else: no address, no user agent. The id is all the seat logic
  // needs, and the row should not become a log of where people were.
  if (!entry) {
    entry = { id: deviceId, kind: 'device', first_seen: nowIso };
    entries.push(entry);
  }
  entry.last_seen = nowIso;
  if (action === 'activate') {
    entry.activated_at = nowIso;
    delete entry.denied_at;
  }

  const holders = seatHolders(entries, seats, now);
  const holds = holders.some((h) => h.id === deviceId);
  if (!holds) {
    entry.denied_at = nowIso;
    const result = invalid(
      'seat_taken',
      'This licence is in use on another PC. Enter the key again here to move it.'
    );
    result.response.seats = seats;
    result.response.seats_used = holders.length;
    result.devices = prune(entries, holders, now);
    return result;
  }

  return {
    valid: true,
    reason: action,
    response: validResponse(row, {
      seats_used: holders.length,
      device: deviceId,
      enforced: true,
    }),
    devices: prune(entries, holders, now),
  };
}

// --- n8n Code node entry point -------------------------------------------
// Present only inside n8n; under `node` this falls through to the export.
if (typeof $input !== 'undefined') {
  const hook = $('Validate License').first().json || {};
  const row = $input.first().json || {};
  const out = decide({ row: row, query: hook.query || {}, headers: hook.headers || {} });
  return [{
    json: {
      response: out.response,
      verdict: out.reason,
      write: !!out.devices,
      row_id: row.id === undefined ? null : row.id,
      devices: out.devices ? JSON.stringify(out.devices) : null,
    },
  }];
}

module.exports = {
  decide,
  parseDevices,
  clientIp,
  normalizeDeviceId,
  seatHolders,
  SEAT_WINDOW_DAYS,
  KEEP_DAYS,
  MAX_LEGACY_ENTRIES,
  MAX_ENTRIES,
};
