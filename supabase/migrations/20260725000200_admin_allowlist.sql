-- Restrict admin access to a named allowlist instead of "anyone signed in".
--
-- The original policy granted reads to any authenticated user, which was only safe while
-- public sign-ups stayed off. That made a dashboard toggle the sole thing standing between
-- a stranger and every guest's mobile number — one setting, easily flipped back on by
-- someone exploring the console, with no error to indicate anything had broken.
--
-- After this, registering an account gets you nothing unless you are also in this table.

create table if not exists admins (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  email    text,
  added_at timestamptz not null default now()
);

alter table admins enable row level security;
-- Deliberately no policies: the table is reachable only through is_admin() below, so an
-- admin cannot enumerate or edit the allowlist from the browser. Adding someone is a
-- deliberate act in the SQL editor.

-- security definer so it can read admins past that table's own RLS. auth.uid() still
-- resolves to the *calling* user — definer changes table privileges, not the JWT.
create or replace function is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

grant execute on function is_admin() to anon, authenticated;

create or replace function require_admin()
returns void language plpgsql stable as $$
begin
  if not public.is_admin() then
    raise exception 'not authorised' using errcode = '42501';
  end if;
end;
$$;

drop policy if exists "signed-in admins read bookings" on bookings;

create policy "allowlisted admins read bookings"
  on bookings for select to authenticated using (is_admin());

-- ---------------------------------------------------------------------------
-- Seed the allowlist. Replace the address with the account you created in
-- Authentication -> Users, then run. Re-running is harmless.
-- ---------------------------------------------------------------------------

insert into admins (user_id, email)
select id, email from auth.users where email = 'info@maidsruscleaning.com.au'
on conflict (user_id) do nothing;

-- Should return exactly one row. If it returns none, the email above did not match any
-- account and admin.html will stay locked out — fix it before deploying the page.
select a.email, a.added_at from admins a;
