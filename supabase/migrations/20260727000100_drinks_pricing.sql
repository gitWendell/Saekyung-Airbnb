-- Drink price management.
--
-- Prices used to be pulled at runtime from a published Google Sheet CSV — a workaround
-- from before this project had a database at all. Everything else guests and the admin
-- touch already lives in Supabase, so prices move here too and get a small admin.html tab
-- instead of a spreadsheet only Diana can find the link to.

create table drinks (
  id         bigserial primary key,
  item       text not null,
  price      numeric(10,2) not null,
  available  boolean not null default true,
  created_at timestamptz not null default now()
);

alter table drinks enable row level security;

-- Guests only ever need what's currently for sale.
create policy "anyone reads available drinks"
  on drinks for select to anon, authenticated using (available = true);

-- Admin can see (and re-enable) unavailable items too, and is the only one who can write.
create policy "admins manage drinks"
  on drinks for all to authenticated using (is_admin()) with check (is_admin());

insert into drinks (item, price) values
  ('Bottled water', 20),
  ('Soft drinks / soda', 35),
  ('Beer', 70),
  ('Juice / energy drink', 45);
