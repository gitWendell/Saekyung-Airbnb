-- The spreadsheet export records when the guest's payment landed, separately from when it
-- was verified. That gap is how long a guest sat waiting on an unverified hold, which is
-- worth keeping — it is the only measure of how fast confirmations actually happen.

alter table bookings add column if not exists paid_at timestamptz;
