-- Saekyung direct booking — initial schema.
--
-- Replaces the n8n workflow that sat between the static pages and a spreadsheet. The
-- business rules that used to live in workflow nodes are functions here, so a booking
-- and everything it cascades into either all happens or none of it does.

create extension if not exists btree_gist;

-- ============================================================================
-- Reference data
-- ============================================================================

create table units (
  code  text primary key,
  label text not null
);

insert into units (code, label) values
  ('B301', 'B301 · 16F City View'),
  ('B305', 'B305 · 15F Pool View');

-- Values the pages used to hardcode. Kept in the database so changing the payment page
-- URL or the hold amount does not mean editing four HTML files.
create table app_settings (
  key   text primary key,
  value text not null
);

insert into app_settings (key, value) values
  ('pay_url',     'https://gitwendell.github.io/Saekyung-Airbnb/pay.html'),
  ('hold_amount', '500');

create or replace function setting(p_key text)
returns text language sql stable as $$
  select value from app_settings where key = p_key
$$;

-- ============================================================================
-- Bookings
-- ============================================================================

-- awaiting_payment  guest filled the form, has not sent money yet
-- pending_payment   guest submitted a payment reference — an unverified hold
-- confirmed         owner/agent matched the reference in GoTyme; the dates are now closed
-- refund_due        lost the race for contested dates, is owed the hold back
-- refunded          money actually sent back
-- blocked           owner closed the dates manually (friend, walk-in, maintenance)
create type booking_status as enum (
  'awaiting_payment',
  'pending_payment',
  'confirmed',
  'refund_due',
  'refunded',
  'blocked'
);

create table bookings (
  booking_id   text primary key,
  unit         text not null references units(code),
  check_in     date not null,
  check_out    date not null,
  status       booking_status not null default 'awaiting_payment',

  guest_name   text,          -- display name; the block label for manual blocks
  fb_name      text,
  email        text,
  mobile       text,
  guests       int not null default 1,

  payment_ref  text,
  confirmed_by text,
  confirmed_at timestamptz,
  refunded_at  timestamptz,
  notes        text,          -- block reason

  created_at   timestamptz not null default now(),

  constraint nights_positive check (check_out > check_in),
  constraint guests_positive check (guests >= 1)
);

-- A stay owns [check_in, check_out), so same-day turnover is not a clash.
--
-- This is the rule the whole migration exists for. Under n8n, "do not double-book" was a
-- check some node remembered to run; two confirmations racing each other could both pass
-- it. Here the database refuses to hold two overlapping closed ranges on one unit at all.
-- Unverified holds are deliberately outside the constraint — they are allowed to overlap,
-- because racing holds is the intended product behaviour.
alter table bookings add constraint no_double_booking
  exclude using gist (
    unit with =,
    daterange(check_in, check_out, '[)') with &&
  ) where (status in ('confirmed', 'blocked'));

create index bookings_status_idx on bookings (status);
create index bookings_unit_dates_idx on bookings (unit, check_in, check_out);

-- SK-A7F3K2 — short enough to read down the phone, unique enough for the volume here.
create or replace function generate_booking_id()
returns text language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no I/O/0/1
  candidate text;
begin
  loop
    candidate := 'SK-' || (
      select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '')
      from generate_series(1, 6)
    );
    exit when not exists (select 1 from bookings where booking_id = candidate);
  end loop;
  return candidate;
end;
$$;

alter table bookings alter column booking_id set default generate_booking_id();

-- ============================================================================
-- Email outbox
-- ============================================================================

-- Mail is queued in the same transaction as the state change that justifies it, then
-- drained by an Edge Function. A booking can therefore never be confirmed without its
-- refund notices being queued, and a Resend outage cannot roll back a confirmation.
create table email_outbox (
  id         bigserial primary key,
  to_email   text not null,
  template   text not null,
  payload    jsonb not null default '{}'::jsonb,
  status     text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  attempts   int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);

create index email_outbox_pending_idx on email_outbox (created_at)
  where status = 'queued';

create or replace function enqueue_email(
  p_booking bookings,
  p_template text
) returns void language plpgsql as $$
begin
  if p_booking.email is null or p_booking.email = '' then
    return;  -- manual blocks have no guest to write to
  end if;

  insert into email_outbox (to_email, template, payload)
  values (
    p_booking.email,
    p_template,
    jsonb_build_object(
      'booking_id',  p_booking.booking_id,
      'guest_name',  coalesce(p_booking.guest_name, p_booking.fb_name, 'Guest'),
      'unit',        p_booking.unit,
      'unit_label',  (select label from units where code = p_booking.unit),
      'check_in',    p_booking.check_in,
      'check_out',   p_booking.check_out,
      'nights',      p_booking.check_out - p_booking.check_in,
      'guests',      p_booking.guests,
      'payment_ref', p_booking.payment_ref,
      'amount',      setting('hold_amount'),
      'pay_url',     setting('pay_url') || '?b=' || p_booking.booking_id
                       || '&unit=' || p_booking.unit
                       || '&check_in=' || p_booking.check_in
                       || '&check_out=' || p_booking.check_out
    )
  );
end;
$$;

-- One place decides which transitions are worth an email, so no caller can forget.
create or replace function on_booking_status_change()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'awaiting_payment' then
      perform enqueue_email(new, 'booking_created');
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    case new.status
      when 'pending_payment' then perform enqueue_email(new, 'payment_received');
      when 'confirmed'       then perform enqueue_email(new, 'booking_confirmed');
      when 'refund_due'      then perform enqueue_email(new, 'refund_due');
      when 'refunded'        then perform enqueue_email(new, 'refund_sent');
      else null;
    end case;
  end if;

  return new;
end;
$$;

create trigger booking_emails
  after insert or update of status on bookings
  for each row execute function on_booking_status_change();

-- ============================================================================
-- Public API — called by the guest-facing pages with the anon key
-- ============================================================================

-- The anon role never reads the bookings table directly (it holds names, emails and
-- mobile numbers). It only calls these functions, which return dates and nothing else.

create or replace function get_availability()
returns jsonb language sql stable security definer set search_path = public as $$
  with ranges as (
    select unit, status, check_in, check_out
    from bookings
    where status in ('confirmed', 'blocked', 'pending_payment')
      and check_out >= current_date
  ),
  closed as (
    select unit, jsonb_agg(jsonb_build_object('check_in', check_in, 'check_out', check_out)
             order by check_in) as list
    from ranges where status in ('confirmed', 'blocked') group by unit
  ),
  held as (
    select unit, jsonb_agg(jsonb_build_object('check_in', check_in, 'check_out', check_out)
             order by check_in) as list
    from ranges where status = 'pending_payment' group by unit
  )
  select jsonb_build_object(
    'units', (
      select coalesce(jsonb_object_agg(u.code, coalesce(c.list, '[]'::jsonb)), '{}'::jsonb)
      from units u left join closed c on c.unit = u.code
    ),
    'holds', (
      select coalesce(jsonb_object_agg(u.code, coalesce(h.list, '[]'::jsonb)), '{}'::jsonb)
      from units u left join held h on h.unit = u.code
    )
  );
$$;

create or replace function create_booking(
  p_unit      text,
  p_check_in  date,
  p_check_out date,
  p_fb_name   text,
  p_email     text,
  p_mobile    text,
  p_guests    int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
  v_holds   int;
begin
  if p_check_out <= p_check_in then
    return jsonb_build_object('unavailable', true, 'reason', 'Check-out must be after check-in.');
  end if;

  if not exists (select 1 from units where code = p_unit) then
    return jsonb_build_object('unavailable', true, 'reason', 'Unknown unit.');
  end if;

  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('unavailable', true, 'reason', 'A valid email is required.');
  end if;

  -- Re-check on the server: the calendar the guest looked at may be minutes stale.
  if exists (
    select 1 from bookings
    where unit = p_unit
      and status in ('confirmed', 'blocked')
      and daterange(check_in, check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
  ) then
    return jsonb_build_object('unavailable', true, 'reason', 'Those dates have just been taken.');
  end if;

  insert into bookings (unit, check_in, check_out, status, guest_name, fb_name, email, mobile, guests)
  values (p_unit, p_check_in, p_check_out, 'awaiting_payment',
          nullif(trim(p_fb_name), ''), nullif(trim(p_fb_name), ''),
          lower(trim(p_email)), nullif(trim(p_mobile), ''), greatest(coalesce(p_guests, 1), 1))
  returning * into v_booking;

  -- Everyone already sitting on an unverified payment for these dates. The guest is told
  -- the count on the payment page so the race is never a surprise.
  select count(*) into v_holds
  from bookings
  where unit = p_unit
    and status = 'pending_payment'
    and booking_id <> v_booking.booking_id
    and daterange(check_in, check_out, '[)') && daterange(p_check_in, p_check_out, '[)');

  return jsonb_build_object(
    'booking_id', v_booking.booking_id,
    'qr_url', setting('pay_url')
      || '?b=' || v_booking.booking_id
      || '&unit=' || v_booking.unit
      || '&check_in=' || v_booking.check_in
      || '&check_out=' || v_booking.check_out
      || '&holds=' || v_holds
  );
end;
$$;

create or replace function submit_payment(
  p_booking_id  text,
  p_payment_ref text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  if p_payment_ref is null or length(trim(p_payment_ref)) < 4 then
    return jsonb_build_object('ok', false, 'error', 'Please enter the reference from your payment app.');
  end if;

  -- Re-submitting from an already-held booking is allowed: guests correct typos in the
  -- reference. Anything already confirmed or refunded is settled and stays untouched.
  update bookings
  set payment_ref = trim(p_payment_ref),
      status = 'pending_payment'
  where booking_id = p_booking_id
    and status in ('awaiting_payment', 'pending_payment')
  returning * into v_booking;

  if v_booking.booking_id is null then
    return jsonb_build_object('ok', false, 'error', 'That booking is no longer awaiting payment.');
  end if;

  return jsonb_build_object('ok', true, 'booking_id', v_booking.booking_id);
end;
$$;

-- ============================================================================
-- Admin API — requires a signed-in Supabase Auth user
-- ============================================================================

create or replace function require_admin()
returns void language plpgsql stable as $$
begin
  if auth.uid() is null then
    raise exception 'not authorised' using errcode = '42501';
  end if;
end;
$$;

create or replace function confirm_booking(
  p_booking_id   text,
  p_confirmed_by text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking  bookings;
  v_refunds  int;
begin
  perform require_admin();

  select * into v_booking from bookings where booking_id = p_booking_id for update;

  if v_booking.booking_id is null then
    return jsonb_build_object('ok', false, 'error', 'Booking not found.');
  end if;

  if v_booking.status = 'confirmed' then
    return jsonb_build_object('ok', true, 'refunds_due', 0, 'note', 'Already confirmed.');
  end if;

  if v_booking.status not in ('awaiting_payment', 'pending_payment') then
    return jsonb_build_object('ok', false, 'error',
      format('That booking is %s and cannot be confirmed.', v_booking.status));
  end if;

  -- Confirming closes the dates, which pushes every other unverified payment on the same
  -- dates into refund_due and emails those guests. Both halves are in this transaction:
  -- if the exclusion constraint rejects the confirmation, nobody gets a refund notice for
  -- a booking that never happened.
  begin
    update bookings
    set status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now()
    where booking_id = p_booking_id;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'error',
      'Those dates are already closed by another confirmed booking or block.');
  end;

  with losers as (
    update bookings
    set status = 'refund_due'
    where unit = v_booking.unit
      and status = 'pending_payment'
      and booking_id <> p_booking_id
      and daterange(check_in, check_out, '[)')
          && daterange(v_booking.check_in, v_booking.check_out, '[)')
    returning 1
  )
  select count(*) into v_refunds from losers;

  return jsonb_build_object('ok', true, 'refunds_due', v_refunds);
end;
$$;

create or replace function mark_refunded(p_booking_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  perform require_admin();

  update bookings
  set status = 'refunded', refunded_at = now()
  where booking_id = p_booking_id and status = 'refund_due'
  returning * into v_booking;

  if v_booking.booking_id is null then
    return jsonb_build_object('ok', false, 'error', 'That booking is not awaiting a refund.');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function block_dates(
  p_unit      text,
  p_check_in  date,
  p_check_out date,
  p_label     text,
  p_reason    text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  perform require_admin();

  if p_check_out <= p_check_in then
    return jsonb_build_object('ok', false, 'error', 'Check-out must be after check-in.');
  end if;

  begin
    insert into bookings (unit, check_in, check_out, status, guest_name, notes, guests)
    values (p_unit, p_check_in, p_check_out, 'blocked',
            coalesce(nullif(trim(p_label), ''), 'Manual block'), p_reason, 1)
    returning * into v_booking;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'error',
      'Those dates are already closed by a confirmed booking or another block.');
  end;

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.booking_id,
    'guest_name', v_booking.guest_name,
    'notes', v_booking.notes
  );
end;
$$;

create or replace function unblock(p_booking_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_deleted int;
begin
  perform require_admin();

  delete from bookings where booking_id = p_booking_id and status = 'blocked';
  get diagnostics v_deleted = row_count;

  if v_deleted = 0 then
    return jsonb_build_object('ok', false, 'error', 'That block no longer exists.');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================================
-- Row level security
-- ============================================================================

alter table bookings     enable row level security;
alter table email_outbox enable row level security;
alter table app_settings enable row level security;
alter table units        enable row level security;

-- No policy for anon on bookings: guest PII is reachable only through the functions above,
-- which return dates and the caller's own booking id.
create policy "signed-in admins read bookings"
  on bookings for select to authenticated using (true);

create policy "anyone reads unit labels"
  on units for select to anon, authenticated using (true);

revoke all on function create_booking(text, date, date, text, text, text, int) from public;
revoke all on function submit_payment(text, text) from public;
revoke all on function get_availability() from public;
revoke all on function confirm_booking(text, text) from public;
revoke all on function mark_refunded(text) from public;
revoke all on function block_dates(text, date, date, text, text) from public;
revoke all on function unblock(text) from public;

grant execute on function get_availability() to anon, authenticated;
grant execute on function create_booking(text, date, date, text, text, text, int) to anon, authenticated;
grant execute on function submit_payment(text, text) to anon, authenticated;

grant execute on function confirm_booking(text, text) to authenticated;
grant execute on function mark_refunded(text) to authenticated;
grant execute on function block_dates(text, date, date, text, text) to authenticated;
grant execute on function unblock(text) to authenticated;
