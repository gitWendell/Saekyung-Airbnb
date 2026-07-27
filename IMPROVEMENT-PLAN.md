# Saekyung Booking System — Improvement Plan

Companion document to the engineering audit performed 2026-07-13. The audit said *what's wrong*; this document says *how each thing gets fixed, with what, and in what order*.

## 1. Scope

Covers all four static pages (`index.html`, `booking-form.html`, `pay.html`, `admin.html`) and the 11 n8n Cloud workflows behind them (9 active, 2 dormant), plus the single `Airbnb Bookings` data table (22 columns) that is the system's only database.

## 2. Guiding principles

- **No rewrite.** The stack is a static site + n8n on purpose — no build step, no hosting bill beyond GitHub Pages + n8n Cloud, no framework to keep patched. Every fix below stays inside that stack.
- **Ship in independent increments.** Each item is deployable and testable on its own — nothing here requires a big-bang cutover.
- **n8n changes go through n8n, not around it.** Where a fix lives in a workflow, it's implemented as an n8n operation (env var, node edit, new workflow), not as a code file checked into this repo — this repo only holds the four static pages.
- **Every change gets a live verification step**, not just "looks right in the editor." That's what caught the actual bug during the original decline-button work (missing data table columns) and it should stay the standard.

## 3. Tech stack

### Current (confirmed, not assumed)

| Layer | Technology |
|---|---|
| Guest frontend | 4 static HTML files, inline `<style>`/`<script>`, no framework, no build step |
| Hosting | GitHub Pages (`gitwendell.github.io/Saekyung-Airbnb`) |
| Backend | n8n Cloud (`cheff-things.app.n8n.cloud`), 11 workflows |
| Database | n8n Data Table (`Airbnb Bookings`, 22 columns, single table) |
| Email | n8n `emailSend` node → Hostinger SMTP credential |
| Payment collection | Static GoTyme QR image, guest self-reports a reference number |
| Auth (admin) | Single shared passcode compared in an `IF` node, sent as `X-Admin-Key` header |
| Auth (guest) | None — booking/payment endpoints are open POST webhooks |

### Target (same stack, specific mechanisms named per fix)

| Layer | Technology / mechanism |
|---|---|
| Admin secret | n8n **environment variable** (`$env.ADMIN_KEY`), not a literal in each node |
| Shared frontend config | One `config.js` file, loaded via `<script src="config.js">` on all four pages |
| Scheduled cleanup | n8n **Schedule Trigger** (cron, daily) → new lightweight workflow |
| Booking history | Extend `Admin Bookings List` workflow's filter + a new "History" tab in `admin.html` (same stack, no new page) |
| Images | Real files under a repo `/images` folder, served by GitHub Pages as static assets, referenced with `<img src>` |
| Payment fraud check | Server-side logic added to the existing `Admin Confirm Booking` workflow (a `Code` node), no new service |

No new frameworks, no new hosting, no new paid services required for anything in Phase 1–4. PayMongo (a real payment gateway) is discussed as an *optional* Phase 5 in §11 because it's the only item that would add a new integration.

## 4. Roadmap

| Phase | Goal | Items | Touches |
|---|---|---|---|
| 1 | Close the two real security gaps | 1.1 – 1.3 | n8n only |
| 2 | Stop data from silently piling up / disappearing | 2.1 – 2.2 | n8n + `admin.html` |
| 3 | Guest-facing trust and page weight | 3.1 – 3.3 | n8n + `pay.html` + `index.html` |
| 4 | Reduce copy-paste drift | 4.1 | all 4 HTML files |

Recommended order: **1 → 2 → 3 → 4**. Phase 1 is pure risk-reduction with zero user-visible change, so it's safe to do first and fast. Phases 2–4 change what guests and you actually see, so they benefit from being done (and tested) one at a time.

---

## 5. Phase 1 — Security & trust

### 1.1 Centralize the admin passcode

**Problem.** `"080925"` is a literal string pasted into 8 `IF` nodes across 5 workflows (`Admin Bookings List`, `Admin Confirm Booking` ×2, `Admin Decline Booking`, `Admin Cancel Booking`, `Admin Block Dates` ×2).

**Approach.** n8n Cloud supports instance-level environment variables. Set one, reference it from every `Check Passcode` node instead of the literal.

**Steps**
1. In n8n: **Settings → Variables** (or environment config, depending on plan tier) → add `ADMIN_KEY = 080925` (or a new, stronger value — this is also the moment to rotate it).
2. In each of the 8 `Check Passcode` IF nodes, change the `rightValue` from the literal `080925` to the expression `{{ $vars.ADMIN_KEY }}` (n8n's variable-access syntax; confirm exact syntax for your n8n plan — self-hosted/Cloud may differ between `$vars` and `$env`).
3. Update the node's existing `notes` field (already says *"edit the value here and in every other Check Passcode node"*) to instead say *"reads from the ADMIN_KEY environment variable — change it in Settings → Variables, not here."*
4. Test each of the 5 workflows with the old literal (should now fail with 401) and the new variable value (should succeed) before calling it done.

**Effort.** ~30 minutes, no frontend change, no downtime — `admin.html` keeps sending the same header, only the backend comparison source changes.

**Verification.** `curl -X POST .../webhook/admin-confirm-booking -H "X-Admin-Key: <old value>"` → expect 401. Repeat with the new value → expect normal behavior. Repeat for all 5 workflows.

---

### 1.2 Remove the unguarded manual block form

**Problem.** `Airbnb — Availability API & Manual Blocks` contains a second, older path to create a `blocked` row — an n8n Form Trigger at `/form/block-dates` — with **no passcode check** and **no overlap validation**, unlike the real `admin-block-dates` webhook that `admin.html`'s calendar uses.

**Approach.** Delete it. `admin.html`'s calendar tap-to-block flow (in `Airbnb — Admin Block Dates`) fully replaces it and is properly validated.

**Steps**
1. Open `Airbnb — Availability API & Manual Blocks` in n8n.
2. Confirm nothing external still links to `/form/block-dates` (check browser bookmarks, any saved links).
3. Delete the `Manual Block Form`, `Prepare Block Row`, `Insert Block`, and `Block Confirmation` nodes (the whole second branch) — leave the `Availability API` (GET) branch untouched, it's a separate, still-needed function in the same workflow.
4. Save and confirm the workflow still activates cleanly with just the read-API branch.

**Effort.** ~10 minutes.

**Verification.** `curl https://cheff-things.app.n8n.cloud/form/block-dates` → should now 404. `curl .../webhook/availability` → should still return the normal `{units, holds}` payload.

---

### 1.3 Payment reference validation + duplicate guard

**Problem.** `pay.html` only checks the reference number is ≥4 characters; nothing checks it looks like a real GoTyme/GCash reference, and nothing checks it isn't already used on another confirmed booking.

**Approach.** Two independent, additive checks — one client-side (better UX, not a security boundary), one server-side (the actual guard).

**Steps — client-side (pay.html)**
1. Replace the `payRef.length < 4` check with a pattern check matching real GoTyme/GCash references (typically 10–13 digits). Suggested: `/^\d{10,15}$/.test(payRef.replace(/\s/g,''))`, adjusted once you confirm the exact format your bank actually issues.
2. Update the inline hint text under the field to say the expected format explicitly (e.g. *"13-digit number from your receipt"*).

**Steps — server-side (n8n, in `Airbnb — Admin Confirm Booking`)**
1. Add a `Code` node between `Confirm Booking` (webhook) and `Check Passcode`, or right after `Mark Confirmed`, that:
   - Fetches all rows where `status = 'confirmed'` and `payment_ref` equals the incoming `payment_ref`.
   - If any match exists (other than the booking being confirmed), short-circuits to a rejection response (`{ ok: false, error: 'This reference number is already attached to a confirmed booking.' }`) instead of proceeding.
2. Wire the existing `Check Passcode` → this new node → `Mark Confirmed` in sequence.
3. Surface the new error string in `admin.html`'s `confirmBooking()` failure handler (it already displays `data.error` when present — no admin.html change needed if the workflow's error message is set correctly).

**Effort.** ~1–2 hours including testing (this is the most involved item in Phase 1).

**Verification.** Confirm one booking with reference `TEST123456789`. Attempt to confirm a second, different booking using the same reference. Second attempt must be rejected with the new error message, and the second booking's status must remain unchanged.

---

## 6. Phase 2 — Data lifecycle & reporting

### 2.1 Inquiry cleanup (scheduled)

**Problem.** Every date-pick on `index.html` that reaches `booking-form.html` writes an `inquiry` row that's permanently invisible in `admin.html` and never expires. 10 accumulated in ~36 hours of testing alone.

**Approach.** A new, small n8n workflow on a daily Schedule Trigger.

**Steps**
1. Create workflow `Airbnb — Cleanup Stale Inquiries`.
2. Node 1: **Schedule Trigger**, daily (e.g. 3:00 AM PH time).
3. Node 2: **Data Table** (`get`, `status = inquiry`, `returnAll: true`).
4. Node 3: **Filter** — keep only rows where `createdAt` (or the workflow-computed age) is older than 7 days.
5. Node 4: **Data Table** (`deleteRows`, matching the filtered `booking_id`s — use the same "match by booking_id" pattern already used in `admin-decline-booking` etc.).
6. Publish and activate.

**Effort.** ~30–45 minutes.

**Verification.** Manually run once against current data (dry-run first if using the `dryRun` option the same way the earlier cleanup used it), confirm only rows older than 7 days with `status = inquiry` are removed, nothing else is touched.

### 2.2 Booking history tab

**Problem.** `Admin Bookings List` only returns `pending_payment / confirmed / blocked / refund_due`. Once a row becomes `refunded`, it's gone from every admin.html view permanently — no way to see completed stays or total refunds without opening n8n directly.

**Approach.** New read-only tab in `admin.html`, backed by a small addition to the existing list workflow (or a second endpoint) that also returns `refunded` rows (and optionally past-checkout `confirmed` rows).

**Steps — n8n**
1. In `Airbnb — Admin Bookings List`, either (a) add `refunded` to the existing `Get Bookings` filter conditions and let `admin.html` split it out client-side by status, or (b) add a second webhook (`admin-history`) with its own `Get Bookings` filtered to `status = refunded`, kept separate so the main Pending/Refunds tabs don't change shape.
   - **Recommended: (a)** — simpler, one round trip, `admin.html` already receives full booking objects and can filter locally like it does for Pending/Refunds today.
2. No email, no cascade logic needed — this is read-only.

**Steps — admin.html**
1. Add a fourth toolbar tab: `📖 History`.
2. Add a `renderHistory()` function filtering `bookings` to `status === 'refunded'` (and optionally `confirmed` with `check_out < today`), rendering guest name, dates, amount, and the relevant `*_at` timestamp per row — no action buttons needed, it's a record, not a queue.
3. Wire it into the existing `TABS` object and `showTab()` mechanism already used for Pending/Refunds/Calendar.

**Effort.** ~1 hour (n8n: 15 min, admin.html: 45 min).

**Verification.** Refund a test booking, confirm it disappears from "Refunds due" and appears in "History" with the correct `refunded_at` timestamp.

---

## 7. Phase 3 — Guest-facing trust & performance

### 3.1 Sender display name on every guest email

**Problem.** All transactional email (confirm, decline, cancel, refund, and your own "guest paid" alert) sends from `info@maidsruscleaning.com.au` with no display name — reads as a phishing red flag to a guest expecting "Saekyung Village."

**Steps**
1. In each `emailSend` node's `fromEmail` field (5 nodes: `Alert Owner`, `Email Guest` in Confirm, `Email Guest` in Decline, `Email Guest` in Cancel, `Email Loser`), change the value from `info@maidsruscleaning.com.au` to `"Saekyung Village" <info@maidsruscleaning.com.au>`.
2. No DNS/domain change required — this is purely the display name the guest's inbox shows.

**Effort.** ~15 minutes.

**Verification.** Trigger one test email per workflow, confirm the "From" name shown in an actual inbox (not just the raw header) reads "Saekyung Village."

### 3.2 Move inline base64 images to real files

**Problem.** `index.html` carries a single ~986KB base64 line (photo gallery); `pay.html` carries two ~322KB base64 lines (QR + logo). Uncacheable, bloats every page load, bloats git history on every photo change.

**Steps**
1. Create `/images` at repo root.
2. Decode the existing base64 blobs back to actual image files (`gallery-1.jpg`, `gallery-2.jpg`, …, `gotyme-qr.png`) — a one-time script (e.g. Python `base64.b64decode`) makes this mechanical and lossless.
3. In `index.html`, replace the `PHOTOS` object's inline `src` data-URIs with relative paths: `src: "images/gallery-1.jpg"`.
4. In `pay.html`, replace the inline `<img>` base64 `src` with `src="images/gotyme-qr.png"`.
5. Commit the new image files alongside the HTML change (one commit, so the diff is reviewable).
6. Optionally add `width`/`height` attributes and `loading="lazy"` to gallery `<img>` tags for better mobile performance, since they're now real cacheable assets.

**Effort.** ~1 hour, mostly mechanical.

**Verification.** Load `index.html` and `pay.html` in a browser with network throttling on, confirm images load from separate cacheable requests (visible in DevTools Network tab) rather than being embedded in the initial HTML payload; confirm page weight of the initial HTML document drops from ~1MB / ~650KB to a few KB.

### 3.3 Data-driven payment recipient *(optional, low priority)*

**Problem.** The GoTyme recipient name is hardcoded directly in `pay.html`'s markup.

**Approach — only if you expect to change payment recipients more than rarely.** Have `pay.html` read the recipient name from the `availability` API response (add a static `payment_recipient` field to that workflow's response) instead of a literal string. Skip this if the recipient essentially never changes — not worth the complexity otherwise.

---

## 8. Phase 4 — Code quality

### 4.1 Shared `config.js`

**Problem.** `UNIT_LABELS`, webhook base URLs, and unit codes are independently copy-pasted in all four HTML files.

**Steps**
1. Create `config.js` at repo root:
   ```js
   const UNIT_LABELS = { B301: "B301 · 16F City View", B305: "B305 · 15F Pool View" };
   const API_BASE = "https://cheff-things.app.n8n.cloud/webhook";
   const CALENDAR_URL = "https://gitwendell.github.io/Saekyung-Airbnb/";
   const BOOKING_FORM_URL = CALENDAR_URL + "booking-form.html";
   ```
2. Add `<script src="config.js"></script>` before each page's own `<script>` block in all four HTML files.
3. Replace each file's locally-defined `UNIT_LABELS` / URL constants with references to the shared ones (e.g. `const AVAILABILITY_API = API_BASE + "/availability";`).
4. No behavior change — this is a pure refactor. Diff each file carefully to confirm no constant was silently dropped.

**Effort.** ~45 minutes, low risk but touches all 4 files — do this last, after Phases 1–3 have already changed some of these files, to minimize merge friction.

**Verification.** Load all four pages, exercise the full guest flow (index → booking-form → pay) and the admin flow once each, confirm nothing broke — this phase should be invisible to any user.

---

## 9. Verification & rollout plan

1. **Phase 1 first, deployed same day if possible** — it's backend-only, zero frontend risk, and closes the two real gaps (shared secret, unguarded form).
2. **After each phase**, re-run the specific verification steps above before moving to the next phase — don't batch multiple phases into one untested deploy.
3. **Any n8n workflow edit** should be tested against a throwaway/test `booking_id` the same way the decline and cancel endpoints were verified earlier (dry-run where the data table node supports it, real curl calls with fake IDs before touching real bookings).
4. **Any `admin.html`/frontend edit** should be checked with `node --check` against the extracted `<script>` block (as done throughout this project) before considering it done, plus a manual click-through of the changed flow.

## 10. Change matrix

| Item | n8n workflows touched | Frontend files touched |
|---|---|---|
| 1.1 Passcode → env var | Admin Bookings List, Admin Confirm Booking, Admin Decline Booking, Admin Cancel Booking, Admin Block Dates | — |
| 1.2 Remove legacy block form | Availability API & Manual Blocks | — |
| 1.3 Payment ref validation + dedupe | Admin Confirm Booking | pay.html |
| 2.1 Inquiry cleanup cron | New: Cleanup Stale Inquiries | — |
| 2.2 Booking history tab | Admin Bookings List | admin.html |
| 3.1 Email display name | Guest Paid Notify, Admin Confirm Booking, Admin Decline Booking, Admin Cancel Booking | — |
| 3.2 Real image files | — | index.html, pay.html (+ new `/images`) |
| 3.3 Data-driven recipient *(optional)* | Availability API & Manual Blocks | pay.html |
| 4.1 Shared config.js | — | all four HTML files (+ new `config.js`) |

## 11. Explicitly deferred (not in this plan)

- **Rate limiting / CAPTCHA on public webhooks** — low priority at current booking volume; revisit only if spam or abuse is actually observed.
- **CORS origin scoping** (`*` → specific domain) — real risk is low given header-based (non-cookie) auth; a nice-to-have, not scheduled.
- **Reviving PayMongo or another automated payment gateway** — the only item that would add a new paid integration to the stack. Worth a separate conversation once/if manual GoTyme verification becomes a real bottleneck at higher booking volume; not scheduled here.
