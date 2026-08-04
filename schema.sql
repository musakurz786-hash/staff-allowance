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
  invoice_url text -- link to the Cin7 invoice PDF, uploaded via the admin panel once the discount sale is processed
);

create index orders_staff_idx on orders(staff_name);
create index orders_period_idx on orders(period);
create index products_product_idx on products using gin (to_tsvector('english', product));

alter table staff enable row level security;
alter table products enable row level security;
alter table orders enable row level security;

-- Internal tool, no staff login system — matches the existing WHIP tool's model of using
-- the anon key for all reads/writes. Not suitable if this were public-facing.
create policy "anon read staff" on staff for select using (true);
create policy "anon insert staff" on staff for insert with check (true);
create policy "anon update staff" on staff for update using (true) with check (true);
create policy "anon delete staff" on staff for delete using (true);
create policy "anon read products" on products for select using (true);
create policy "anon write products" on products for all using (true) with check (true);
create policy "anon read orders" on orders for select using (true);
create policy "anon insert orders" on orders for insert with check (true);
create policy "anon update orders" on orders for update using (true) with check (true);
create policy "anon delete orders" on orders for delete using (true);

-- Storage bucket "invoices" for uploaded Cin7 invoice PDFs. Create the bucket itself via the
-- Supabase dashboard (Storage -> New bucket -> name "invoices" -> toggle Public ON), then run this:
create policy "anon upload invoices" on storage.objects for insert with check (bucket_id = 'invoices');
create policy "anon read invoices" on storage.objects for select using (bucket_id = 'invoices');
