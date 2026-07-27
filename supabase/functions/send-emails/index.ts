/// <reference types="jsr:@supabase/functions-js/edge-runtime.d.ts" />
// Drains email_outbox through Resend.
//
// Invoked by a Database Webhook on insert into email_outbox. It always drains the whole
// queue rather than the row it was handed, so a row whose delivery failed earlier gets
// another attempt on the next event without needing a separate retry job.

import { createClient } from "jsr:@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
// Guests see the display name, not the address, in every mail client — so booking mail
// reads as "Saekyung Village" while replies land in the one inbox the client monitors.
const FROM = Deno.env.get("MAIL_FROM") ?? "Saekyung Village <info@maidsruscleaning.com.au>";
const REPLY_TO = Deno.env.get("MAIL_REPLY_TO") ?? "info@maidsruscleaning.com.au";
const MESSENGER = Deno.env.get("MESSENGER_URL") ?? "https://m.me/dayanabusiness0";

const MAX_ATTEMPTS = 5;
const BATCH = 25;

type Payload = {
  booking_id: string;
  guest_name: string;
  unit: string;
  unit_label: string;
  check_in: string;
  check_out: string;
  nights: number;
  guests: number;
  payment_ref: string | null;
  amount: string;
  pay_url: string;
  directory_passcode: string | null;
  directory_url: string | null;
};

const fmt = (iso: string) =>
  new Date(`${iso}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });

function layout(heading: string, body: string) {
  return `<div style="font-family:'Segoe UI',system-ui,-apple-system,sans-serif;color:#1b2a2f;line-height:1.6;max-width:520px;margin:0 auto;padding:24px">
  <h1 style="font-size:22px;font-weight:600;margin:0 0 16px">${heading}</h1>
  ${body}
  <p style="color:#a89f8c;font-size:12px;border-top:1px solid #e2ddd2;margin-top:28px;padding-top:14px">
    Saekyung Village · Direct Booking — reply here or message us on
    <a href="${MESSENGER}" style="color:#0e7c86">Messenger</a>.
  </p>
</div>`;
}

function stayBox(p: Payload) {
  return `<div style="background:#d5ecee;border:1px solid #0e7c86;border-radius:12px;padding:14px 16px;margin:16px 0">
    <div style="font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:#0e7c86;font-weight:600">Your stay</div>
    <div style="font-size:16px;font-weight:600;margin-top:2px">${p.unit_label}</div>
    <div>${fmt(p.check_in)} → ${fmt(p.check_out)} · ${p.nights} night${p.nights === 1 ? "" : "s"} · ${p.guests} guest${p.guests === 1 ? "" : "s"}</div>
    <div style="margin-top:6px;font-size:13px">Reference <b>${p.booking_id}</b></div>
  </div>`;
}

const templates: Record<string, (p: Payload) => { subject: string; html: string }> = {
  booking_created: (p) => ({
    subject: `Hold your dates — ${p.unit_label} (${p.booking_id})`,
    html: layout(`Hi ${p.guest_name}, your dates are waiting`, `
      <p>We've saved your details. The dates aren't held until the ₱${p.amount} reservation
      fee is paid and we've verified it.</p>
      ${stayBox(p)}
      <p style="text-align:center;margin:24px 0">
        <a href="${p.pay_url}" style="display:inline-block;background:#0e7c86;color:#fff;text-decoration:none;padding:14px 26px;border-radius:12px;font-weight:600">
          Pay the ₱${p.amount} reservation fee
        </a>
      </p>
      <p style="font-size:13px;color:#4a5b60">GCash, Maya or bank transfer via GoTyme QR.</p>`),
  }),

  payment_received: (p) => ({
    subject: `We got your reference — verifying now (${p.booking_id})`,
    html: layout(`Thanks ${p.guest_name} — we're checking your payment`, `
      <p>Your reference <b>${p.payment_ref ?? "—"}</b> is in. We verify payments by hand
      against our GoTyme account, usually within a few hours.</p>
      ${stayBox(p)}
      <div style="background:#fdf2d8;border:1px solid #f4b740;border-radius:12px;padding:13px 15px;font-size:13px;color:#6d4f10">
        <b style="display:block;color:#5a4300;margin-bottom:3px">These dates aren't closed yet</b>
        Someone else may have paid for them too. Whoever we verify first gets the room — and
        if that isn't you, your ₱${p.amount} comes back in full, automatically.
      </div>`),
  }),

  booking_confirmed: (p) => ({
    subject: `Confirmed — ${p.unit_label}, ${fmt(p.check_in)} (${p.booking_id})`,
    html: layout(`You're confirmed, ${p.guest_name} 🎉`, `
      <p>We matched your payment. The dates are now closed to everyone else — the room is yours.</p>
      ${stayBox(p)}
      <p>The ₱${p.amount} reservation fee comes off your balance on arrival. We'll message you
      before check-in with directions and the key handover.</p>
      ${p.directory_passcode ? `<div style="background:#fdf6e8;border:1px solid #d8b879;border-radius:12px;padding:14px 16px;margin:16px 0;text-align:center">
        <div style="font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:#8a6626;font-weight:600">Your guest directory passcode</div>
        <div style="font-size:28px;font-weight:700;letter-spacing:.08em;margin:6px 0;font-family:ui-monospace,Menlo,monospace">${p.directory_passcode}</div>
        <p style="font-size:13px;color:#4a5b60;margin:0 0 10px">WiFi, keys, pool passes and everything else for your unit.</p>
        <a href="${p.directory_url}" style="display:inline-block;background:#8a6626;color:#fff;text-decoration:none;padding:10px 20px;border-radius:10px;font-weight:600;font-size:13px">
          Open your guest directory
        </a>
      </div>` : ""}`),
  }),

  refund_due: (p) => ({
    subject: `Refund on the way — ${p.booking_id}`,
    html: layout(`Sorry ${p.guest_name} — someone was verified first`, `
      <p>Another guest's payment for these dates landed and was verified ahead of yours. We
      told you this could happen, and we meant the other half of it too:
      <b>your ₱${p.amount} is coming back in full</b>, within 24 hours. You don't need to chase us.</p>
      ${stayBox(p)}
      <p>If you'd like a different date or the other unit, just reply — we'll sort it out.</p>`),
  }),

  refund_sent: (p) => ({
    subject: `Your ₱${p.amount} has been sent back (${p.booking_id})`,
    html: layout(`Refund sent, ${p.guest_name}`, `
      <p>We've sent your ₱${p.amount} back through GoTyme. It usually lands right away, but can
      take a little longer depending on your bank or e-wallet.</p>
      ${stayBox(p)}
      <p>If it hasn't arrived in 24 hours, reply to this email and we'll chase it.</p>`),
  }),
};

async function send(to: string, subject: string, html: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from: FROM, to, subject, html, reply_to: REPLY_TO }),
  });
  if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
}

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: rows, error } = await supabase
    .from("email_outbox")
    .select("*")
    .eq("status", "queued")
    .lt("attempts", MAX_ATTEMPTS)
    .order("created_at", { ascending: true })
    .limit(BATCH);

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  let sent = 0;
  let failed = 0;

  for (const row of rows ?? []) {
    const build = templates[row.template];
    try {
      if (!build) throw new Error(`Unknown template "${row.template}"`);
      const { subject, html } = build(row.payload as Payload);
      await send(row.to_email, subject, html);
      await supabase
        .from("email_outbox")
        .update({ status: "sent", sent_at: new Date().toISOString(), attempts: row.attempts + 1 })
        .eq("id", row.id);
      sent++;
    } catch (e) {
      const attempts = row.attempts + 1;
      // Stays 'queued' until it runs out of attempts, so the next invocation retries it.
      await supabase
        .from("email_outbox")
        .update({
          attempts,
          last_error: String(e),
          status: attempts >= MAX_ATTEMPTS ? "failed" : "queued",
        })
        .eq("id", row.id);
      failed++;
    }
  }

  return new Response(JSON.stringify({ sent, failed, scanned: rows?.length ?? 0 }), {
    headers: { "Content-Type": "application/json" },
  });
});
