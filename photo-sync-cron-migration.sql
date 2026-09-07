-- Run this once in the Supabase SQL Editor (after enabling pg_cron and pg_net via
-- Dashboard -> Database -> Extensions — already done as of 2026-09-04).
--
-- Schedules a daily job that does exactly what Admin -> Import Product Photos -> Apply does, but
-- unattended: fetches freedomofmovement.co.za's public product feed page by page, matches by SKU,
-- and updates products.image_url — entirely inside Postgres via pg_net, no external secret or
-- service needed. Every run is logged to photo_sync_log so you can check whether it's working
-- without digging through pg_cron's own internals.
--
-- Written against the exact function signatures confirmed live on this project
-- (pg_cron 1.6.4, pg_net 0.20.4): net.http_get(...) returns a request id immediately; the
-- synchronous net.http_collect_response(request_id, async := false) blocks until that request
-- resolves (bounded by http_get's own timeout_milliseconds) and returns a
-- net.http_response_result — a (status, message, response) record where `response` is itself a
-- (status_code, headers, body) record, hence the `(v_result.response).status_code` parenthesized
-- field access below (composite-field-of-a-composite needs the parens to parse correctly).

create table if not exists photo_sync_log (
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
  v_max_pages int := 12; -- ~3000 products of headroom — the live catalog is ~780 today (~4 pages)
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

    -- one photo per SKU: the product's first image, applied to every variant SKU under it — same
    -- "first image, per variant" matching the client-side Import Product Photos button already uses
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

    exit when v_product_count < 250; -- last page of the feed
    v_page := v_page + 1;
  end loop;

  insert into photo_sync_log(pages_fetched, updated_count, status, detail)
  values (v_total_pages, v_total_updated, 'ok', null);
exception when others then
  insert into photo_sync_log(pages_fetched, updated_count, status, detail)
  values (v_total_pages, v_total_updated, 'error', sqlerrm);
end;
$$ language plpgsql security definer;

-- idempotent: safe to re-run this whole migration (e.g. to change the schedule below) without
-- ending up with two competing jobs of the same name
do $$
begin
  if exists (select 1 from cron.job where jobname = 'sync-product-photos') then
    perform cron.unschedule('sync-product-photos');
  end if;
end $$;

-- 03:00 UTC = 05:00 SAST, well outside store hours. Change the cron expression here and re-run
-- this migration if you want a different time.
select cron.schedule('sync-product-photos', '0 3 * * *', $$select sync_product_photos();$$);
