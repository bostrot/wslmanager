// Writes the licence email. Everything comes from Build licence, which read
// the re-fetched, verified Stripe session; Save licence has just stored the
// same row. Plain HTML with inline styles so every mail client renders it.
function compose(licence) {
const key = String(licence.license_key || '').toUpperCase();
const commercial = licence.plan === 'commercial';
const team = licence.plan === 'team';
const seats = Number(licence.seats) || 1;
const to = String(licence.email || '').trim();
const sessionId = String(licence.session_id || '');

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[c]));

const product = commercial
  ? 'WSL Manager Commercial'
  : team
    ? 'WSL Manager Team'
    : 'WSL Manager Pro';
// A Team licence runs for the year that was billed; say until when.
const until = team && licence.expires && !Number.isNaN(new Date(licence.expires).getTime())
  ? new Date(licence.expires).toISOString().slice(0, 10)
  : '';
const seatText = seats === 1 ? '1 seat' : `${seats} seats`;
const licencePage = `https://wslmanager.com/buy/success/?session_id=${encodeURIComponent(sessionId)}`;

const intro = commercial
  ? `Thank you for buying a commercial licence for WSL Manager — ${seatText}, perpetual, no renewal. Share the key below with your team; each person pastes it into their own install.`
  : team
    ? `Thank you for choosing the WSL Manager Team plan — ${seatText}, renewing every year${until ? ` (the current period runs until ${until})` : ''}. Share the key below with your team; each person pastes it into their own install, and once every seat is taken the newest activation wins.`
    : 'Thank you for buying WSL Manager Pro. Your licence is perpetual and covers every machine you use yourself. Here is your key:';

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Your ${esc(product)} licence key</title>
</head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#111827;">
  <div style="display:none;max-height:0;overflow:hidden;">Your ${esc(product)} licence key is inside.</div>
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3f4f6;padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;background:#ffffff;border-radius:16px;border:1px solid #e5e7eb;overflow:hidden;">
        <tr><td style="padding:28px 32px 0 32px;">
          <table role="presentation" cellspacing="0" cellpadding="0"><tr>
            <td style="vertical-align:middle;"><img src="https://wslmanager.com/img/logo.png" width="40" height="40" alt="" style="display:block;border-radius:10px;"></td>
            <td style="vertical-align:middle;padding-left:12px;font-size:18px;font-weight:600;color:#111827;">WSL Manager</td>
          </tr></table>
        </td></tr>
        <tr><td style="padding:28px 32px 0 32px;">
          <h1 style="margin:0;font-size:26px;line-height:1.25;font-weight:600;letter-spacing:-0.01em;color:#111827;">You&rsquo;re all set</h1>
          <p style="margin:14px 0 0 0;font-size:16px;line-height:1.6;color:#4b5563;">${esc(intro)}</p>
        </td></tr>
        <tr><td style="padding:24px 32px 0 32px;">
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:12px;">
            <tr><td style="padding:18px 20px;">
              <p style="margin:0 0 8px 0;font-size:11px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#6b7280;">Your licence key</p>
              <p style="margin:0;font-family:SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace;font-size:18px;line-height:1.5;letter-spacing:0.02em;color:#111827;word-break:break-all;">${esc(key)}</p>
            </td></tr>
          </table>
        </td></tr>
        <tr><td style="padding:24px 32px 0 32px;">
          <p style="margin:0 0 10px 0;font-size:15px;font-weight:600;color:#111827;">How to activate</p>
          <ol style="margin:0;padding-left:20px;font-size:15px;line-height:1.7;color:#4b5563;">
            <li>Open WSL Manager on Windows or macOS.</li>
            <li>Go to <strong style="color:#111827;">Upgrade to Pro</strong> in the sidebar.</li>
            <li>Paste the key and press <strong style="color:#111827;">Activate</strong>.</li>
          </ol>
          <p style="margin:14px 0 0 0;font-size:14px;line-height:1.6;color:#6b7280;">Bought on your Mac? Your <a href="${licencePage}" style="color:#0891b2;text-decoration:none;font-weight:600;">licence page</a> has an <em>Activate in WSL Manager</em> button that hands the key to the app for you.</p>
        </td></tr>
        <tr><td style="padding:28px 32px 0 32px;">
          <table role="presentation" cellspacing="0" cellpadding="0"><tr>
            <td style="background:#06b6d4;border-radius:10px;">
              <a href="${licencePage}" style="display:inline-block;padding:12px 22px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;">Open your licence page</a>
            </td>
          </tr></table>
        </td></tr>
        <tr><td style="padding:28px 32px 28px 32px;">
          <p style="margin:0;font-size:13px;line-height:1.6;color:#6b7280;">Keep this email — it is your proof of purchase. Questions, more seats, or a lost key: reply to this email or write to <a href="mailto:license@bostrot.com" style="color:#0891b2;text-decoration:none;">license@bostrot.com</a>.</p>
        </td></tr>
      </table>
      <p style="margin:18px 0 0 0;font-size:12px;line-height:1.6;color:#9ca3af;">Sent by Eric Trenkel &middot; WSL Manager &middot; <a href="https://wslmanager.com" style="color:#9ca3af;text-decoration:none;">wslmanager.com</a></p>
    </td></tr>
  </table>
</body>
</html>`;

const text = [
  `Thank you for buying ${product}${commercial ? ` (${seatText})` : ''}${team ? ` (${seatText}, renews yearly${until ? `, current period until ${until}` : ''})` : ''}.`,
  '',
  `Your licence key: ${key}`,
  '',
  'How to activate: open WSL Manager, go to "Upgrade to Pro" in the sidebar, paste the key and press Activate.',
  `Your licence page: ${licencePage}`,
  '',
  'Keep this email as your proof of purchase. Questions or a lost key: license@bostrot.com',
].join('\n');

return {
  to,
  subject: `Your ${product} licence key`,
  html,
  text,
  // Nothing to send to; the row is saved and the licence page still works.
  skip: !to || licence.resent === true,
};
}

// --- n8n Code node entry point -------------------------------------------
// Present only inside n8n; under `node` this falls through to the export.
if (typeof $input !== 'undefined') {
  return [{ json: compose($('Build licence').item.json) }];
}

module.exports = { compose };
