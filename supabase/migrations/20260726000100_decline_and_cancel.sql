-- Decline and cancel, ported from the n8n endpoints admin-decline-booking and
-- admin-cancel-booking.
--
-- Both end at refund_due, because both take money from a guest who has already paid:
--   decline  — reject a guest whose payment is still unverified
--   cancel   — undo a confirmation that has already been made
--
-- Neither status closes dates, so cancelling a confirmed stay frees the calendar as a
-- side effect of the status change. Nothing has to remember to unblock anything.
--
-- The refund_due email fires from the existing booking_emails trigger, so a declined or
-- cancelled guest is told they are owed ₱500 without either function mentioning email.

alter table bookings
  add column if not exists declined_by   text,
  add column if not exists declined_at   timestamptz,
  add column if not exists cancelled_by  text,
  add column if not exists cancelled_at  timestamptz;

create or replace function decline_booking(
  p_booking_id  text,
  p_declined_by text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  perform require_admin();

  -- Only a guest who actually paid can be declined. Declining an awaiting_payment row
  -- would move someone who never sent money into the refunds list and put you on the hook
  -- for ₱500 you were never given.
  update bookings
  set status = 'refund_due',
      declined_by = p_declined_by,
      declined_at = now()
  where booking_id = p_booking_id
    and status = 'pending_payment'
  returning * into v_booking;

  if v_booking.booking_id is null then
    return jsonb_build_object('ok', false, 'error',
      'That booking is not a pending payment — only unverified payments can be declined.');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function cancel_booking(
  p_booking_id   text,
  p_cancelled_by text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_booking bookings;
begin
  perform require_admin();

  update bookings
  set status = 'refund_due',
      cancelled_by = p_cancelled_by,
      cancelled_at = now()
  where booking_id = p_booking_id
    and status = 'confirmed'
  returning * into v_booking;

  if v_booking.booking_id is null then
    return jsonb_build_object('ok', false, 'error',
      'That booking is not confirmed, so there is nothing to cancel.');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function decline_booking(text, text) from public;
revoke all on function cancel_booking(text, text) from public;

grant execute on function decline_booking(text, text) to authenticated;
grant execute on function cancel_booking(text, text) to authenticated;
