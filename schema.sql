-- Staff Allowance & Discount Portal — Supabase schema
-- Run this once in the Supabase SQL Editor on a new project.

create table staff (
  id bigint generated always as identity primary key,
  name text not null unique,
  email text,
  period text not null default '2026',
  allowance numeric not null default 0,
  balance numeric not null default 0
);

create table products (
  sku text primary key,
  product text not null,
  category text,
  subcat text,
  rsp numeric not null default 0,
  available numeric default 0,
  updated_at timestamptz default now()
);

create table orders (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  staff_name text not null references staff(name),
  sku text, -- intentionally no FK to products: order history must survive a product being discontinued/removed later
  product text not null,
  qty int not null default 1,
  order_type text not null check (order_type in ('allowance','discount')),
  rsp numeric not null,
  amount numeric not null, -- allowance orders: amount deducted from balance. discount orders: amount payable by staff.
  period text not null,
  invoiced boolean not null default false,
  invoice_url text, -- link to the Cin7 invoice PDF, uploaded via the admin panel once the discount sale is processed
  is_historical boolean not null default false, -- backfilled from the old spreadsheet, pre-dating the app.
    -- Balances were seeded as a fixed number that already accounts for these, so cancelling one must NOT refund it.
  order_group_id text, -- ties together every line item placed in the same cart submission, so a
    -- multi-item order gets exactly one Cin7 invoice and one confirmation/invoice email, matching
    -- how Cin7 actually invoices a whole purchase rather than per line item.
  is_topup boolean not null default false -- true when this discount-type row is the pay-in
    -- remainder of a split Staff Allowance purchase (charged at full RSP, not the 40% staff
    -- discount), rather than an ordinary staff-discount purchase. Still needs Cin7 invoicing like
    -- any other discount-type row, just at a different rate — see split-payment-migration.sql.
);

create index orders_staff_idx on orders(staff_name);
create index orders_period_idx on orders(period);
create index products_product_idx on products using gin (to_tsvector('english', product));

alter table staff enable row level security;
alter table products enable row level security;
alter table orders enable row level security;

-- ============================================================================
-- Access model: staff log in with their own email (Supabase Auth magic link).
-- Everyone can only see/touch their own staff row and their own orders; the
-- one exception is the admin email below, which gets full access to
-- everything — this is the "master admin" (Musa). Update the constant in
-- every policy below if the admin's email ever changes; one admin account
-- doesn't justify a config table + join just to parameterize this.
-- ============================================================================

-- staff: everyone can read their own row (for their balance/allowance); admin reads all.
create policy "read own staff row, admin reads all" on staff for select
  using (email = auth.jwt()->>'email' or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

-- staff: only admin can add/remove staff records.
create policy "admin insert staff" on staff for insert
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "admin delete staff" on staff for delete
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

-- staff: admin can update any column on any row; a regular staff member can only touch their own
-- row, and (via the trigger below) only its `balance` column — that's what lets the app deduct an
-- allowance purchase from your own balance without letting you edit your name/email/allowance or
-- anyone else's balance.
create policy "own row balance update, admin updates all" on staff for update
  using (email = auth.jwt()->>'email' or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (email = auth.jwt()->>'email' or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

create or replace function staff_guard_update() returns trigger as $$
begin
  if auth.jwt()->>'email' = 'musa@freedomofmovement.co.za' then
    return new; -- admin may change anything
  end if;
  if old.email is distinct from new.email
     or old.name is distinct from new.name
     or old.allowance is distinct from new.allowance
     or old.period is distinct from new.period then
    raise exception 'Not permitted to modify this field';
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger staff_guard_update_trigger before update on staff
  for each row execute function staff_guard_update();

-- products: the full catalog is visible to any logged-in staff member (needed to browse/order);
-- only admin can add/edit/import.
create policy "any logged-in user reads products" on products for select
  using (auth.role() = 'authenticated');
create policy "admin writes products" on products for all
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

-- orders: you can only see your own order history; admin sees everyone's.
create policy "read own orders, admin reads all" on orders for select
  using (
    staff_name = (select name from staff where email = auth.jwt()->>'email')
    or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za'
  );
-- orders: you can only place an order under your own name (prevents ordering as someone else);
-- admin can insert on anyone's behalf (used for historical backfills).
create policy "insert own orders, admin inserts any" on orders for insert
  with check (
    staff_name = (select name from staff where email = auth.jwt()->>'email')
    or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za'
  );
-- orders: cancelling, invoicing, editing are admin-only actions (matches the admin panel — staff
-- have no order-editing UI at all).
create policy "admin updates orders" on orders for update
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "admin deletes orders" on orders for delete
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

-- Storage bucket "invoices" for uploaded Cin7 invoice PDFs. Create the bucket itself via the
-- Supabase dashboard (Storage -> New bucket -> name "invoices" -> toggle Public ON), then run this.
-- Only admin uploads invoices; the bucket is Public so the PDF links in emails work for anyone
-- without needing to be logged in — being Public bypasses these policies for plain GETs by URL,
-- these only govern API-level access (uploads and listing).
create policy "admin uploads invoices" on storage.objects for insert
  with check (bucket_id = 'invoices' and auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "anon read invoices" on storage.objects for select using (bucket_id = 'invoices');
