-- Kick the send-emails Edge Function whenever mail is queued.
--
-- This is what the dashboard's "Database Webhooks" feature builds for you; doing it here
-- keeps it in version control with the rest of the schema and avoids depending on the
-- supabase_functions schema that feature installs.
--
-- The call is fire-and-forget: pg_net queues the request and returns immediately, so a slow
-- or down Resend can never hold up the transaction that queued the mail. If the request is
-- lost entirely, the row simply stays 'queued' and the next insert drains it.

create extension if not exists pg_net;

create or replace function drain_email_outbox()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url     := 'https://rbcqeuygpevabqwtdgva.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      -- The anon key, not the service role key. The function only needs the caller to pass
      -- JWT verification; it uses its own injected service role key internally. Keeping the
      -- privileged key out of a trigger definition means it is not sitting in the catalog.
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJiY3FldXlncGV2YWJxd3RkZ3ZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ5Njk2OTQsImV4cCI6MjEwMDU0NTY5NH0.X9qiG3XjGHzT-O5b8lO0DeJKzzJu_ocMr4LAh3-0WLA'
    ),
    body    := '{}'::jsonb
  );
  return null;
end;
$$;

-- Statement-level: confirming a booking queues several emails in one statement, and one
-- wake-up drains them all. Per-row would fire redundant calls for the same batch.
drop trigger if exists email_outbox_drain on email_outbox;

create trigger email_outbox_drain
  after insert on email_outbox
  for each statement execute function drain_email_outbox();
