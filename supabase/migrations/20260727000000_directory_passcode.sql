-- Guest directory access passcode.
--
-- guest-directory.html used to have no access control at all: anyone with the link could
-- browse every unit's WiFi password and key instructions by just picking a room. Confirming
-- a booking now stamps it with a short passcode that unlocks only that unit, for that guest,
-- for as long as the booking stays 'confirmed' — cancel it and the passcode stops working
-- with no extra bookkeeping, because redeem_passcode below checks status the same way every
-- other guest-facing function does.

alter table bookings add column if not exists directory_passcode text unique;

-- Same shape as generate_booking_id() (init.sql): short, no ambiguous characters, looped
-- until unique. A different column, so collisions with booking_id values don't matter.
create or replace function generate_directory_passcode()
returns text language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
begin
  loop
    select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '')
    into candidate
    from generate_series(1, 6);
    exit when not exists (select 1 from bookings where directory_passcode = candidate);
  end loop;
  return candidate;
end;
$$;

insert into app_settings (key, value) values
  ('directory_url', 'https://gitwendell.github.io/Saekyung-Airbnb/guest-directory.html')
on conflict (key) do nothing;

-- ============================================================================
-- confirm_booking — re-declared to stamp a passcode the first time a booking is
-- confirmed. coalesce() means re-confirming (the "already confirmed" no-op path returns
-- before this runs anyway) can never rotate a code that has already been emailed out.
-- ============================================================================

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
    set status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now(),
        directory_passcode = coalesce(directory_passcode, generate_directory_passcode())
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

-- ============================================================================
-- enqueue_email — re-declared to carry the passcode and a ready-to-click directory link
-- into the email payload. Harmless for every other template: the column is null until a
-- booking is confirmed, so directory_url resolves to null right alongside it.
-- ============================================================================

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
                       || '&check_out=' || p_booking.check_out,
      'directory_passcode', p_booking.directory_passcode,
      'directory_url', case when p_booking.directory_passcode is not null
                          then setting('directory_url') || '?code=' || p_booking.directory_passcode
                          else null end
    )
  );
end;
$$;

-- ============================================================================
-- Public API — anon-callable, mirrors get_availability(): reads nothing but dates and the
-- caller's own booking info, gated on the passcode matching a currently-confirmed booking.
-- ============================================================================

create or replace function redeem_passcode(p_passcode text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  select * into v_booking
  from bookings
  where directory_passcode = upper(trim(coalesce(p_passcode, '')))
    and status = 'confirmed';

  if v_booking.booking_id is null then
    return jsonb_build_object('ok', false, 'error', 'That passcode was not recognized.');
  end if;

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.booking_id,
    'unit', v_booking.unit,
    'unit_label', (select label from units where code = v_booking.unit),
    'guest_name', coalesce(v_booking.guest_name, v_booking.fb_name, 'Guest'),
    'check_in', v_booking.check_in,
    'check_out', v_booking.check_out
  );
end;
$$;

revoke all on function redeem_passcode(text) from public;
grant execute on function redeem_passcode(text) to anon, authenticated;
