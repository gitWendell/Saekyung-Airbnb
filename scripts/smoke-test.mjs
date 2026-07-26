// Exercises every RPC against a real Supabase project, including the rules that only
// matter when two guests collide. The SQL has never run before it reaches your project,
// so this is what stands between "it deployed" and "it works".
//
//   SUPABASE_URL=https://abc.supabase.co \
//   SUPABASE_ANON_KEY=eyJ... \
//   ADMIN_EMAIL=you@x.com ADMIN_PASSWORD=... \
//   SUPABASE_SERVICE_KEY=eyJ...  \
//   node scripts/smoke-test.mjs
//
// The service key is used only to delete the rows this test creates. It is read from the
// environment and never written to a file. Run this before enabling the email webhook, or
// the test bookings will queue real mail to a nonexistent address.

const { SUPABASE_URL, SUPABASE_ANON_KEY, ADMIN_EMAIL, ADMIN_PASSWORD, SUPABASE_SERVICE_KEY } = process.env;

for (const [k, v] of Object.entries({ SUPABASE_URL, SUPABASE_ANON_KEY, ADMIN_EMAIL, ADMIN_PASSWORD })) {
  if (!v) { console.error(`Missing ${k}`); process.exit(1); }
}

const BASE = SUPABASE_URL.replace(/\/$/, '');
const UNIT = 'B301';
// Far enough out that it can never overlap a real stay, and obvious in the table if a
// cleanup ever fails to run.
const CHECK_IN = '2099-01-10';
const CHECK_OUT = '2099-01-13';

let pass = 0, fail = 0;
const created = [];
let token = null;

const ok = (name, cond, detail) => {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? `\n          ${detail}` : ''}`); }
};

async function rpc(fn, args, useAdmin) {
  const auth = useAdmin && token ? token : SUPABASE_ANON_KEY;
  const r = await fetch(`${BASE}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json', Accept: 'application/json',
      apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${auth}`,
    },
    body: JSON.stringify(args || {}),
  });
  const text = await r.text();
  let body; try { body = JSON.parse(text); } catch { body = text; }
  return { status: r.status, body };
}

async function book(email) {
  const { body } = await rpc('create_booking', {
    p_unit: UNIT, p_check_in: CHECK_IN, p_check_out: CHECK_OUT,
    p_fb_name: 'Smoke Test', p_email: email, p_mobile: '09170000000', p_guests: 2,
  });
  if (body?.booking_id) created.push(body.booking_id);
  return body;
}

console.log(`\nSmoke test against ${BASE}\n`);

// ---------------------------------------------------------------- public surface
console.log('Guest flow');

const avail = await rpc('get_availability');
ok('get_availability returns units and holds',
  avail.status === 200 && avail.body?.units && avail.body?.holds,
  JSON.stringify(avail.body).slice(0, 200));
ok('availability covers both units',
  avail.body?.units?.B301 !== undefined && avail.body?.units?.B305 !== undefined);

const a = await book('smoke-a@example.com');
ok('create_booking returns a payment link', !!a?.qr_url && !!a?.booking_id, JSON.stringify(a).slice(0, 200));
ok('payment link carries the booking id and hold count',
  a?.qr_url?.includes(`b=${a.booking_id}`) && a?.qr_url?.includes('holds='));

const bad = await rpc('create_booking', {
  p_unit: UNIT, p_check_in: CHECK_IN, p_check_out: CHECK_OUT,
  p_fb_name: 'Bad Email', p_email: 'not-an-email', p_mobile: '', p_guests: 1,
});
ok('create_booking rejects a malformed email', bad.body?.unavailable === true);

// The whole product rests on this: unverified holds are allowed to pile up on the same
// dates. If this ever starts failing, guests are being turned away before they can race.
const b = await book('smoke-b@example.com');
ok('a second guest may hold the same dates', !!b?.booking_id && b.booking_id !== a?.booking_id);

ok('submit_payment accepts a reference',
  (await rpc('submit_payment', { p_booking_id: a.booking_id, p_payment_ref: 'SMOKE-REF-A' })).body?.ok === true);
ok('submit_payment accepts the rival too',
  (await rpc('submit_payment', { p_booking_id: b.booking_id, p_payment_ref: 'SMOKE-REF-B' })).body?.ok === true);
ok('submit_payment rejects a too-short reference',
  (await rpc('submit_payment', { p_booking_id: a.booking_id, p_payment_ref: 'x' })).body?.ok === false);
ok('submit_payment rejects an unknown booking',
  (await rpc('submit_payment', { p_booking_id: 'SK-NOPE00', p_payment_ref: 'SMOKE-REF' })).body?.ok === false);

const held = await rpc('get_availability');
const holds = held.body?.holds?.[UNIT] ?? [];
ok('both payments now show as holds on the calendar',
  holds.filter(h => h.check_in === CHECK_IN).length >= 2, JSON.stringify(holds).slice(0, 200));
ok('holds do not close the dates',
  !(held.body?.units?.[UNIT] ?? []).some(u => u.check_in === CHECK_IN));

// ---------------------------------------------------------------- the security boundary
console.log('\nAccess control');

const leak = await fetch(`${BASE}/rest/v1/bookings?select=email,mobile&limit=1`, {
  headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
});
const leaked = await leak.json().catch(() => null);
ok('anon cannot read guest names, emails or mobiles',
  leak.status === 401 || leak.status === 403 || (Array.isArray(leaked) && leaked.length === 0),
  `got ${leak.status} ${JSON.stringify(leaked).slice(0, 120)}`);

ok('anon cannot confirm a booking',
  (await rpc('confirm_booking', { p_booking_id: a.booking_id, p_confirmed_by: 'Hacker' })).status >= 400);
ok('anon cannot block dates',
  (await rpc('block_dates', { p_unit: UNIT, p_check_in: '2099-06-01', p_check_out: '2099-06-02', p_label: 'x', p_reason: 'x' })).status >= 400);

const signIn = await fetch(`${BASE}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY },
  body: JSON.stringify({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD }),
});
const sess = await signIn.json();
token = sess.access_token;
ok('admin can sign in', !!token, sess.error_description || sess.msg || '');
if (!token) { console.log('\nCannot continue without an admin session.'); process.exit(1); }

const list = await fetch(`${BASE}/rest/v1/bookings?select=*&status=in.(pending_payment,confirmed,refund_due,refunded,blocked)`, {
  headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
});
const rows = await list.json();
ok('signed-in admin reads the bookings table', Array.isArray(rows), JSON.stringify(rows).slice(0, 200));
ok('admin list hides never-paid bookings', Array.isArray(rows) && !rows.some(r => r.status === 'awaiting_payment'));

// ---------------------------------------------------------------- the rules that matter
console.log('\nBooking rules');

const conf = await rpc('confirm_booking', { p_booking_id: a.booking_id, p_confirmed_by: 'Owner' }, true);
ok('confirming works', conf.body?.ok === true, JSON.stringify(conf.body).slice(0, 200));
// Confirming one guest is what puts the other out of pocket. If this count is wrong,
// someone paid and is never told they are getting it back.
ok('confirming cascades the rival to refund_due', conf.body?.refunds_due === 1,
  `refunds_due = ${conf.body?.refunds_due}, expected 1`);

const rival = await rpc('confirm_booking', { p_booking_id: b.booking_id, p_confirmed_by: 'Agent' }, true);
ok('the losing rival can no longer be confirmed', rival.body?.ok === false, JSON.stringify(rival.body).slice(0, 200));

// The exclusion constraint, tested directly: a manual block over confirmed dates is the
// same double-booking the old workflow could let through.
const clash = await rpc('block_dates',
  { p_unit: UNIT, p_check_in: '2099-01-11', p_check_out: '2099-01-12', p_label: 'Clash', p_reason: 'Other' }, true);
ok('dates cannot be blocked over a confirmed stay', clash.body?.ok === false, JSON.stringify(clash.body).slice(0, 200));

const closed = await rpc('get_availability');
ok('the confirmed stay now closes the dates',
  (closed.body?.units?.[UNIT] ?? []).some(u => u.check_in === CHECK_IN));

const late = await book('smoke-c@example.com');
ok('new guests are turned away from closed dates', late?.unavailable === true, JSON.stringify(late).slice(0, 200));

ok('the losing guest can be marked refunded',
  (await rpc('mark_refunded', { p_booking_id: b.booking_id }, true)).body?.ok === true);
ok('refunding twice is refused',
  (await rpc('mark_refunded', { p_booking_id: b.booking_id }, true)).body?.ok === false);

const blk = await rpc('block_dates',
  { p_unit: 'B305', p_check_in: '2099-03-01', p_check_out: '2099-03-04', p_label: 'Smoke block', p_reason: 'Maintenance' }, true);
ok('free dates can be blocked', blk.body?.ok === true, JSON.stringify(blk.body).slice(0, 200));
if (blk.body?.booking_id) created.push(blk.body.booking_id);
ok('a block can be removed',
  (await rpc('unblock', { p_booking_id: blk.body?.booking_id }, true)).body?.ok === true);

// ---------------------------------------------------------------- cleanup
console.log('\nCleanup');
if (SUPABASE_SERVICE_KEY) {
  const ids = created.filter(Boolean);
  const del = await fetch(`${BASE}/rest/v1/bookings?booking_id=in.(${ids.join(',')})`, {
    method: 'DELETE',
    headers: { apikey: SUPABASE_SERVICE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_KEY}` },
  });
  await fetch(`${BASE}/rest/v1/email_outbox?to_email=like.smoke-*`, {
    method: 'DELETE',
    headers: { apikey: SUPABASE_SERVICE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_KEY}` },
  });
  ok('test rows removed', del.ok, `status ${del.status}`);
} else {
  console.log(`  SKIP  no SUPABASE_SERVICE_KEY — delete these by hand:`);
  console.log(`        delete from bookings where booking_id in (${created.map(i => `'${i}'`).join(', ')});`);
  console.log(`        delete from email_outbox where to_email like 'smoke-%';`);
}

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
