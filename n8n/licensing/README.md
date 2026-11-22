# Licensing workflow

`wsl-manager-licensing.workflow.json` is the export of the **WSL Manager
Licensing** workflow on n8n. It issues keys from Stripe events, answers the
app's AI queries, and — the part kept under test here — validates licence keys
at `GET /webhook/wsl-manager/validate`.

Import it in n8n with **Workflows → … → Import from File** (or `PUT
/api/v1/workflows/<id>` with `name`, `nodes`, `connections`, `settings`), then
activate it. It needs a `devices` string column on the `wsl-manager-licenses`
data table.

## One PC per seat

A licence has `seats` (1 for Pro, the purchased quantity for commercial). The
validator hands seats to devices, newest activation first:

| Request | Outcome |
|---|---|
| `?license=K&device=D&action=activate` | D takes a seat. If all seats are taken, the least recently activated holder is displaced. Always `valid: true`. |
| `?license=K&device=D&action=revalidate` | `valid: true` while D still holds a seat; otherwise `valid: false, reason: "seat_taken"`. Never changes who holds a seat. |
| `?license=K` (no device) | Behaves exactly as before seats existed: `valid: true` for an active, unexpired key. The caller's address is noted in `devices` as `ip:…`, so sharing is at least visible; nothing is enforced. |

So two PCs sharing one key keep displacing each other: whoever entered the key
last has Pro, the other is asked to enter it again at its next check. A
customer moving to a new PC activates there and is never asked anything; the
old PC is told `seat_taken` at its next 14‑day check.

A holder unseen for 90 days frees its seat; devices unseen for 180 days are
dropped from the row. `device` is at most 64 characters of `[A-Za-z0-9._:-]`;
anything else falls back to the no-device path.

Responses:

```json
{ "valid": true, "plan": "pro", "expires_at": "2099-12-31T00:00:00.000Z",
  "is_trial": false, "seats": 1, "seats_used": 1, "email": "…",
  "device": "D", "enforced": true }

{ "valid": false, "reason": "seat_taken", "seats": 1, "seats_used": 1,
  "message": "This licence is in use on another PC. …" }
```

Other `reason` values: `unknown_key`, `inactive`, `expired`. The app only reads
`valid`, `plan`, `seats` and `email`; the rest is for people looking at logs.

## What the app has to send

The decision is only as good as the two query parameters. Until the app sends
`device` and `action`, every request takes the no-device row above and nothing
is enforced. `lib/api/license_manager.dart` would add a stable per-install id
(the Windows `MachineGuid` / macOS `IOPlatformUUID`, hashed) as `device`, and
pass `action=activate` from a key the user typed in versus
`action=revalidate` from the 14‑day background check.

## Files

| File | What |
|---|---|
| `seat_check.js` | The "Seat check" Code node, verbatim. Pure `decide()` plus a thin n8n wrapper. |
| `seat_check_test.js` | `node --test n8n/licensing/seat_check_test.js`. Covers the table above, seat ageing, pruning, hostile input, and that the export embeds `seat_check.js` unchanged. |
| `wsl-manager-licensing.workflow.json` | The export. Regenerate the Code node from `seat_check.js` when the logic changes — the test fails if they drift. |

## Validate branch

```
Validate License (webhook)
  → Find licence (data table get by lower-cased key, always outputs one item)
  → Seat check (Code: decide(), see above)
  → Respond verdict (JSON from Seat check)
  → Devices changed? → Store devices (data table update `devices` by row id)
```

Unknown keys used to end with no Respond node reached, which the app read as
a network error rather than a rejection; `Find licence` now always emits an
item so `Seat check` can answer `unknown_key`.
