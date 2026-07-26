# Migrating off n8n to Supabase

The pages used to call eight n8n webhooks. They now call Postgres functions directly.
There is no application server: Supabase holds the data and the rules, one Edge Function
sends mail, and the pages stay on GitHub Pages exactly as they are.

| Was | Now |
| --- | --- |
| `GET /webhook/availability` | `rpc/get_availability` |
| `POST /webhook/airbnb-book` | `rpc/create_booking` |
| `POST /webhook/airbnb-paid` | `rpc/submit_payment` |
| `GET /webhook/admin-bookings` | `GET /rest/v1/bookings` (row level security) |
| `POST /webhook/admin-confirm-booking` | `rpc/confirm_booking` |
| `POST /webhook/admin-mark-refunded` | `rpc/mark_refunded` |
| `POST /webhook/admin-block-dates` | `rpc/block_dates` |
| `POST /webhook/admin-unblock` | `rpc/unblock` |
| n8n "Send email" nodes | `email_outbox` table + `send-emails` Edge Function |
| `X-Admin-Key` header checked in n8n | Supabase Auth session |

Response shapes were kept identical, so no rendering code in the pages changed.

## 1. Create the project

```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase db push          # applies supabase/migrations/20260725000000_init.sql
```

## 2. Create the admin account

Dashboard → Authentication → Users → **Add user**. Use a real address you control, tick
**Auto Confirm User**, and set the password to whatever you want the admin passcode to be.

Then turn **off** public sign-ups: Authentication → Sign In / Providers → Email →
*Allow new users to sign up*.

Then edit `20260725000200_admin_allowlist.sql`, replacing `REPLACE-WITH-YOUR-ADMIN-EMAIL`
with that address, and run it. It moves admin access from "any signed-in user" to a named
allowlist, so a stranger who registers an account gets nothing even if sign-ups are somehow
re-enabled later. The final `select` must return exactly one row — if it returns none, the
email didn't match and `admin.html` will stay locked out.

## 3. Deploy the mailer

Booking mail sends from `info@maidsruscleaning.com.au` — the client keeps every inbound
reply in one inbox. Guests see the display name, so it reads as **Saekyung Village** in the
mail client and only shows the address on inspection.

**Verify the domain in Resend first.** Add a domain, choose `maidsruscleaning.com.au`, and
add the records it generates. Resend puts the Return-Path on a `send.` subdomain, so:

- **The existing SPF record on the root domain is not touched.** Adding a second `v=spf1`
  TXT record to a domain that already sends business mail would break *that* mail — SPF
  permits exactly one record per name. If Resend's instructions ever appear to ask for a
  root-level SPF change, stop and merge into the existing record instead of adding one.
- The DKIM record (`resend._domainkey`) and the `send.` subdomain records are additive and
  safe alongside Google Workspace or Microsoft 365.

Since this is a live business domain, have whoever manages its DNS make the change.

```bash
supabase secrets set RESEND_API_KEY=re_xxx
supabase secrets set MAIL_FROM="Saekyung Village <info@maidsruscleaning.com.au>"
supabase secrets set MAIL_REPLY_TO="info@maidsruscleaning.com.au"
supabase functions deploy send-emails
```

Sending before the domain shows **Verified** in Resend will bounce every message.

Then Dashboard → Database → **Webhooks** → Create:

- Table `email_outbox`, event **Insert**
- Type **Supabase Edge Function** → `send-emails`
- Add header `Authorization: Bearer <service role key>`

The function drains the whole queue on every invocation, not just the row that triggered it,
so a message that failed earlier gets retried by the next booking's event. After five failed
attempts a row is marked `failed` and left alone.

## 4. Point the pages at the project

Take the Project URL and the **anon** key from Dashboard → Settings → API, then:

```bash
node scripts/set-config.mjs --url https://YOUR-REF.supabase.co --key eyJ... --admin you@yourdomain.com
```

That writes `SUPABASE_URL` and `SUPABASE_ANON_KEY` into all four pages and `ADMIN_EMAIL`
into `admin.html`. It refuses to run if the key is the service role one, and writes nothing
at all unless every page checks out — a half-migrated site is worse than an unmigrated one.
Re-run it any time you rotate the key.

The anon key belongs in public HTML — that is what it is for. It grants exactly what the
policies allow, which for guests is three functions returning dates and their own booking id.
The `bookings` table itself has no anon policy, so guest names, emails and mobile numbers are
unreachable without signing in. **Never put the service role key in these files.**

Also update `app_settings.pay_url` if the site ever moves off `gitwendell.github.io`:

```sql
update app_settings set value = 'https://…/pay.html' where key = 'pay_url';
```

## 5. Bring the old bookings across

Export the sheet n8n was writing to, then generate the import from it:

```bash
node scripts/import-history.mjs "path/to/Airbnb Bookings.csv"
```

That writes `supabase/migrations/20260725000100_import_history.sql`. Run
`20260725000050_add_paid_at.sql` first — the export records when payment landed, which the
original schema had nowhere to put.

The script checks the history for overlapping confirmed or blocked stays **before** writing
anything, and prints the offending pairs instead of generating a file the exclusion
constraint would reject wholesale. Re-run it any time the export changes; the generated SQL
is `on conflict do nothing`, so applying it twice is harmless.

Two things it does that matter:

- **The email trigger is disabled around the insert.** Without that, importing queues a
  "your dates are waiting" email to every abandoned inquiry in the back catalogue — real
  addresses, for bookings weeks dead.
- **The old `inquiry` status becomes `awaiting_payment`.** Those guests filled the form and
  never paid, so they hold nothing and are owed nothing. They are kept for history but hidden
  from the admin list.

Original `BK-nnn` / `BLK-nnn` ids are preserved. New bookings use `SK-XXXXXX`, so the two
formats can never collide.

## 6. Verify before you switch

This SQL has never executed anywhere before it reaches your project, so prove it works
before a guest does. Run this **before** wiring up the email webhook in step 3, or the test
bookings will queue mail to a nonexistent address:

```bash
SUPABASE_URL=https://YOUR-REF.supabase.co \
SUPABASE_ANON_KEY=eyJ... \
ADMIN_EMAIL=you@yourdomain.com ADMIN_PASSWORD=your-passcode \
SUPABASE_SERVICE_KEY=eyJ... \
node scripts/smoke-test.mjs
```

It books two guests onto the same dates, pays for both, confirms one, and checks that the
loser cascades to `refund_due`, that the loser can no longer be confirmed, that the dates
can't then be blocked over, and that a new guest is turned away. It also checks that the
anon key **cannot** read guest emails and mobiles. The service key is only used to delete
the rows it made; leave it out and it prints the two `delete` statements instead.

Everything it creates lives in 2099, so it can't collide with a real stay.

## 7. Switch over

Deploy the pages, make one real booking end to end, then **pause** the n8n workflows rather
than deleting them. Keep them for a week — if something is wrong, re-running
`scripts/set-config.mjs` against nothing and restoring the old webhook URLs is the whole
rollback.

## What changed in behaviour

- **Double-booking is now impossible, not merely checked.** An exclusion constraint on
  `(unit, [check_in, check_out))` refuses to store two overlapping confirmed or blocked
  ranges. Two admins confirming rival bookings at the same instant no longer race: the second
  one gets a clean "those dates are already closed" instead of a silently double-sold room.
- **Confirming is one transaction.** Setting a booking confirmed and pushing every rival hold
  to `refund_due` now succeed or fail together. Previously a workflow could stop halfway and
  leave a confirmed booking whose losing guests were never told.
- **New status `awaiting_payment`.** A booking starts here and only becomes `pending_payment`
  when the guest submits a reference. That makes the calendar's "N other guests have already
  paid" literally true — before, it counted anyone who had merely opened the form. These rows
  are hidden from the admin list, since they hold nothing and are owed nothing.
- **`pay.html` no longer sends the unit and dates.** They are read from the booking row, so
  editing the query string can't alter someone else's stay.
- **Emails are queued, then sent.** A Resend outage delays mail instead of failing bookings.

## Templates in `send-emails`

`booking_created`, `payment_received`, `booking_confirmed`, `refund_due`, `refund_sent`.

`refund_due` is the one the pages explicitly promise ("we refund your ₱500 in full,
automatically" — [booking-form.html](booking-form.html), [pay.html](pay.html)). The other
four are reconstructed from what the flow implies rather than from the old n8n nodes, so
compare them against what your guests actually receive today. Deleting a key from the
`templates` map stops that email; the queue row is just marked failed and nothing else breaks.
