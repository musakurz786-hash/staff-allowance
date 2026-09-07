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
  image_url text, -- pulled from freedomofmovement.co.za's public Shopify product feed by SKU,
    -- via Admin -> Import Product Photos. Not populated by the Cin7 stock import or Shopify
    -- pricing import — those don't carry a photo.
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
  -- a non-admin may only ever decrease their own balance (spending it) — closes a direct-API
  -- loophole where nothing else stopped them PATCHing their own balance up, and with no trace
  if new.balance > old.balance then
    raise exception 'Not permitted to increase your own balance';
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger staff_guard_update_trigger before update on staff
  for each row execute function staff_guard_update();

-- Atomic balance adjustment — every balance change (order checkout, admin edit, refund) should go
-- through this rather than a client-side GET-then-PATCH-absolute-value, which races: two
-- concurrent writes can silently clobber each other. The increment happens inside one UPDATE
-- statement, which Postgres serializes safely regardless of how stale the caller's own view of
-- "current balance" was. A caller may only adjust their own row, unless they're admin.
create or replace function adjust_staff_balance(p_name text, p_delta numeric) returns numeric as $$
declare
  v_email text;
  v_new numeric;
begin
  select email into v_email from staff where name = p_name;
  if not found then
    raise exception 'Staff not found: %', p_name;
  end if;
  if auth.jwt()->>'email' <> 'musa@freedomofmovement.co.za'
     and (v_email is null or auth.jwt()->>'email' is distinct from v_email) then
    raise exception 'Not permitted to adjust this balance';
  end if;
  update staff set balance = balance + p_delta where name = p_name returning balance into v_new;
  return v_new;
end;
$$ language plpgsql security definer;

grant execute on function adjust_staff_balance(text, numeric) to authenticated;

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

-- ============================================================================
-- staff_audit + order amount validation — see improvements-migration.sql for the full comments.
-- Kept here too so a fresh setup gets these from the start.
-- ============================================================================
create table staff_audit (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  staff_name text not null,
  field text not null check (field in ('allowance','balance','period')),
  old_value text,
  new_value text,
  changed_by text not null,
  source text not null
);
alter table staff_audit enable row level security;
create policy "admin only" on staff_audit for all
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

create or replace function validate_order_amount() returns trigger as $$
declare
  v_rsp numeric;
  v_expected numeric;
begin
  -- a null auth.jwt() means this insert didn't come through PostgREST at all (e.g. a direct SQL
  -- Editor session doing a historical backfill) — exempt those the same as the admin, since a
  -- genuine anonymous/staff request through the app's public API always has some JWT set
  if auth.jwt() is null or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za' then
    return new;
  end if;
  select rsp into v_rsp from products where sku = new.sku;
  if v_rsp is null then
    raise exception 'Unknown SKU %', new.sku;
  end if;
  if new.rsp is distinct from v_rsp then
    raise exception 'RSP mismatch for % — submitted % but catalog says %', new.sku, new.rsp, v_rsp;
  end if;
  if new.order_type = 'discount' and not new.is_topup then
    v_expected := round(v_rsp * new.qty * (1 - 0.40), 2); -- keep in sync with CONFIG.DISCOUNT_RATE
  else
    v_expected := v_rsp * new.qty;
  end if;
  if abs(new.amount - v_expected) > 0.01 then
    raise exception 'Amount mismatch for % — submitted % but expected %', new.sku, new.amount, v_expected;
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger validate_order_amount_trigger before insert on orders
  for each row execute function validate_order_amount();

-- ============================================================================
-- Daily product-photo sync — see photo-sync-cron-migration.sql for the full comments. Kept here
-- too so a fresh setup gets it from the start. Requires the pg_cron and pg_net extensions enabled
-- via Dashboard -> Database -> Extensions before this will run.
-- ============================================================================
create table photo_sync_log (
  id bigint generated always as identity primary key,
  run_at timestamptz not null default now(),
  pages_fetched int not null default 0,
  updated_count int not null default 0,
  status text not null, -- 'ok' | 'error'
  detail text
);
alter table photo_sync_log enable row level security;
create policy "admin only" on photo_sync_log for all
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

create or replace function sync_product_photos() returns void as $$
declare
  v_page int := 1;
  v_max_pages int := 12;
  v_request_id bigint;
  v_result net.http_response_result;
  v_status_code int;
  v_body jsonb;
  v_count int;
  v_product_count int;
  v_total_pages int := 0;
  v_total_updated int := 0;
begin
  loop
    exit when v_page > v_max_pages;

    v_request_id := net.http_get(
      url := 'https://www.freedomofmovement.co.za/products.json?limit=250&page=' || v_page,
      timeout_milliseconds := 15000
    );
    v_result := net.http_collect_response(v_request_id, async := false);
    v_status_code := (v_result.response).status_code;

    if v_status_code is distinct from 200 then
      insert into photo_sync_log(pages_fetched, updated_count, status, detail)
      values (v_total_pages, v_total_updated, 'error',
        'Page '||v_page||' failed — status '||coalesce(v_status_code::text,'null')||
        ', pg_net status '||coalesce(v_result.status::text,'null')||': '||coalesce(v_result.message,''));
      return;
    end if;

    v_body := (v_result.response).body::jsonb;
    v_product_count := jsonb_array_length(coalesce(v_body->'products', '[]'::jsonb));
    v_total_pages := v_total_pages + 1;

    with prod as (
      select p as product from jsonb_array_elements(coalesce(v_body->'products','[]'::jsonb)) as p
    ),
    img as (
      select product, (product->'images'->0->>'src') as image_url
      from prod
      where jsonb_array_length(coalesce(product->'images','[]'::jsonb)) > 0
    ),
    var as (
      select image_url, (v->>'sku') as sku
      from img, jsonb_array_elements(coalesce(product->'variants','[]'::jsonb)) as v
      where v->>'sku' is not null
    )
    update products p
    set image_url = var.image_url, updated_at = now()
    from var
    where p.sku = var.sku and p.image_url is distinct from var.image_url;
    get diagnostics v_count = row_count;
    v_total_updated := v_total_updated + v_count;

    exit when v_product_count < 250;
    v_page := v_page + 1;
  end loop;

  insert into photo_sync_log(pages_fetched, updated_count, status, detail)
  values (v_total_pages, v_total_updated, 'ok', null);
exception when others then
  insert into photo_sync_log(pages_fetched, updated_count, status, detail)
  values (v_total_pages, v_total_updated, 'error', sqlerrm);
end;
$$ language plpgsql security definer;

select cron.schedule('sync-product-photos', '0 3 * * *', $$select sync_product_photos();$$);
