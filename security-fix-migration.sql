-- Security fix, part 1 of 2 (2026-10-05). Run in the Supabase SQL Editor.
--
-- SAFE TO RUN WHILE THE OLD index.html IS STILL LIVE: everything here is additive or tightens
-- something the old page never relied on. Once the new index.html is deployed, run
-- security-lockdown-migration.sql (part 2) to close the old direct-write paths.
--
-- What this fixes:
--   1. adjust_staff_balance() was callable by anyone holding only the public key: its admin check
--      evaluated to NULL (not true) for a JWT with no email, so it never raised, and EXECUTE had
--      never been revoked from anon/public. Anyone could drain any staff member's balance.
--   2. Checkout was two separate client calls (insert orders, then deduct) with no server-side
--      balance check — double-clicks charged twice, a failure between the two left an order with no
--      deduction, and a staff member could insert allowance orders without ever being charged.
--      place_order() now does price lookup, split, insert and deduction in ONE locked transaction,
--      and is idempotent per order_group_id (a retry of the same cart can never charge twice).
--   3. Admin cancel/remove refunded first, then deleted — a failed delete or double click refunded
--      twice. admin_delete_orders() deletes and refunds atomically, from the rows actually deleted.
--   4. startNewPeriod looped PATCH calls from the browser; a failure partway left staff on mixed
--      periods. start_new_period() does it in one statement.
--   5. Defence-in-depth constraints so bad values can't be stored even by a buggy client:
--      qty > 0, non-negative amounts, a safe order_group_id format, https-only invoice links.
--   6. Every SECURITY DEFINER function gets a fixed search_path.

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
create or replace function is_admin() returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(lower(auth.jwt()->>'email'), '') = 'musa@freedomofmovement.co.za';
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. adjust_staff_balance: NULL-safe auth, no anon access, no name probing
-- ---------------------------------------------------------------------------------------------
-- Non-admins may still call it on their own row with a NEGATIVE delta only, because the old
-- index.html (live until part 2) deducts that way. Part 2 makes it admin-only.
create or replace function adjust_staff_balance(p_name text, p_delta numeric) returns numeric
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_caller text := lower(auth.jwt()->>'email');
  v_email text;
  v_new numeric;
begin
  if v_caller is null then
    raise exception 'Not permitted to adjust this balance';
  end if;
  select email into v_email from staff where name = p_name;
  -- same message whether the name exists or not, so non-admins can't probe for staff names
  if not is_admin() and (not found or v_email is null or lower(v_email) <> v_caller or p_delta > 0) then
    raise exception 'Not permitted to adjust this balance';
  end if;
  if not found then
    raise exception 'Staff not found: %', p_name;
  end if;
  update staff set balance = balance + p_delta where name = p_name returning balance into v_new;
  return v_new;
end;
$$;

revoke execute on function adjust_staff_balance(text, numeric) from public, anon;
grant execute on function adjust_staff_balance(text, numeric) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. Server-side checkout
-- ---------------------------------------------------------------------------------------------
-- Works out every order line from the live catalog (never from client-supplied prices), including
-- the allowance/pay-in split. Internal only — called by quote_order() and place_order().
--   p_items: [{"sku": "...", "qty": 2}, ...] in cart order; duplicate SKUs are merged.
create or replace function _order_plan(p_order_type text, p_items jsonb, p_balance numeric) returns jsonb
language plpgsql stable
set search_path = public, pg_temp
as $$
declare
  v_discount_rate constant numeric := 0.40; -- keep in sync with CONFIG.DISCOUNT_RATE and validate_order_amount()
  v_item record;
  v_lines jsonb := '[]'::jsonb;
  v_remaining numeric := greatest(coalesce(p_balance, 0), 0);
  v_covered int;
  v_topup int;
  v_total_rsp numeric := 0;
  v_allowance_total numeric := 0;
  v_topup_total numeric := 0;
  v_payable_total numeric := 0;
  v_amount numeric;
begin
  if p_order_type not in ('allowance','discount') then
    raise exception 'BAD_REQUEST: unknown order type';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'BAD_REQUEST: empty cart';
  end if;
  if jsonb_array_length(p_items) > 50 then
    raise exception 'BAD_REQUEST: too many lines in one order';
  end if;

  for v_item in
    with raw as (
      select e->>'sku' as sku,
             case when (e->>'qty') ~ '^[0-9]{1,4}$' then (e->>'qty')::int else null end as qty,
             pos
      from jsonb_array_elements(p_items) with ordinality as t(e, pos)
    ), merged as (
      select sku, sum(qty)::int as qty, min(pos) as pos, bool_or(qty is null) as bad_qty
      from raw group by sku
    )
    select m.sku, m.qty, m.bad_qty, p.product, p.rsp, p.available
    from merged m left join products p on p.sku = m.sku
    order by m.pos
  loop
    if v_item.bad_qty or v_item.qty is null or v_item.qty < 1 or v_item.qty > 20 then
      raise exception 'BAD_QTY: %', v_item.sku;
    end if;
    if v_item.product is null then
      raise exception 'UNKNOWN_PRODUCT: %', v_item.sku;
    end if;
    if not (v_item.rsp > 0) then
      raise exception 'NOT_PRICED: %', v_item.product;
    end if;
    if coalesce(v_item.available, 0) < v_item.qty then
      raise exception 'OUT_OF_STOCK: %', v_item.product;
    end if;

    v_total_rsp := v_total_rsp + v_item.rsp * v_item.qty;

    if p_order_type = 'discount' then
      v_amount := round(v_item.rsp * v_item.qty * (1 - v_discount_rate), 2);
      v_payable_total := v_payable_total + v_amount;
      v_lines := v_lines || jsonb_build_object('sku', v_item.sku, 'product', v_item.product, 'qty', v_item.qty,
        'order_type', 'discount', 'rsp', v_item.rsp, 'amount', v_amount, 'is_topup', false);
    else
      -- whole units per line: as many as the remaining balance covers, the rest becomes a
      -- full-price pay-in (same allocation the old client did, now in exact numeric maths)
      v_covered := least(v_item.qty, floor(v_remaining / v_item.rsp)::int);
      v_topup := v_item.qty - v_covered;
      if v_covered > 0 then
        v_amount := v_item.rsp * v_covered;
        v_remaining := v_remaining - v_amount;
        v_allowance_total := v_allowance_total + v_amount;
        v_lines := v_lines || jsonb_build_object('sku', v_item.sku, 'product', v_item.product, 'qty', v_covered,
          'order_type', 'allowance', 'rsp', v_item.rsp, 'amount', v_amount, 'is_topup', false);
      end if;
      if v_topup > 0 then
        v_amount := v_item.rsp * v_topup;
        v_topup_total := v_topup_total + v_amount;
        v_lines := v_lines || jsonb_build_object('sku', v_item.sku, 'product', v_item.product, 'qty', v_topup,
          'order_type', 'discount', 'rsp', v_item.rsp, 'amount', v_amount, 'is_topup', true);
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'lines', v_lines,
    'total_rsp', v_total_rsp,
    'allowance_total', v_allowance_total,
    'topup_total', v_topup_total,
    'payable_total', v_payable_total,
    'is_split', v_topup_total > 0
  );
end;
$$;

revoke execute on function _order_plan(text, jsonb, numeric) from public, anon, authenticated;

-- Read-only preview: what this cart would cost right now, including any split. The client shows
-- this in the confirm step and passes the totals back to place_order(), which refuses to go ahead
-- if anything (price or balance) moved in between.
create or replace function quote_order(p_staff_name text, p_order_type text, p_items jsonb) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_caller text := lower(auth.jwt()->>'email');
  v_staff staff%rowtype;
begin
  select * into v_staff from staff where name = p_staff_name;
  if v_caller is null or not found or not (is_admin() or lower(v_staff.email) = v_caller) then
    raise exception 'NOT_PERMITTED';
  end if;
  return _order_plan(p_order_type, p_items, v_staff.balance)
    || jsonb_build_object('balance', v_staff.balance, 'allowance', v_staff.allowance);
end;
$$;

revoke execute on function quote_order(text, text, jsonb) from public, anon;
grant execute on function quote_order(text, text, jsonb) to authenticated;

-- The only way staff orders get written. One transaction, staff row locked for its duration:
-- concurrent checkouts for the same person queue up instead of both spending the same balance.
create or replace function place_order(
  p_staff_name text,
  p_order_type text,
  p_items jsonb,
  p_group_id text,
  p_expected jsonb  -- {"allowance_total":..,"topup_total":..,"payable_total":..} from quote_order()
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_caller text := lower(auth.jwt()->>'email');
  v_staff staff%rowtype;
  v_plan jsonb;
  v_line jsonb;
  v_balance_after numeric;
begin
  -- lock first, so the balance read below can't change until this transaction ends
  select * into v_staff from staff where name = p_staff_name for update;
  if v_caller is null or not found or not (is_admin() or lower(v_staff.email) = v_caller) then
    raise exception 'NOT_PERMITTED';
  end if;

  if p_group_id is null or p_group_id !~ '^[A-Za-z0-9_.-]{8,100}$' then
    raise exception 'BAD_REQUEST: invalid order reference';
  end if;
  -- idempotency: the client keeps the same group id for every retry of one cart, so a retry after
  -- a timeout/double-click reports the original order instead of placing (and charging) it again
  if exists (select 1 from orders where order_group_id = p_group_id) then
    if exists (select 1 from orders where order_group_id = p_group_id and staff_name <> p_staff_name) then
      raise exception 'BAD_REQUEST: order reference already used';
    end if;
    return jsonb_build_object('status', 'duplicate', 'balance_after', v_staff.balance);
  end if;

  v_plan := _order_plan(p_order_type, p_items, v_staff.balance);

  if p_order_type = 'allowance' then
    if v_staff.balance <= 0 then
      raise exception 'NO_BALANCE';
    end if;
    if (v_plan->>'allowance_total')::numeric = 0 then
      -- every unit costs more than what's left: a "split" would be 100% full-price pay-in, which is
      -- strictly worse for them than a Staff Discount purchase — make them choose that instead
      raise exception 'NO_ALLOWANCE_COVER';
    end if;
  end if;

  if p_expected is null
     or abs((v_plan->>'allowance_total')::numeric - coalesce((p_expected->>'allowance_total')::numeric, -1)) > 0.005
     or abs((v_plan->>'topup_total')::numeric - coalesce((p_expected->>'topup_total')::numeric, -1)) > 0.005
     or abs((v_plan->>'payable_total')::numeric - coalesce((p_expected->>'payable_total')::numeric, -1)) > 0.005 then
    raise exception 'QUOTE_CHANGED';
  end if;

  for v_line in select * from jsonb_array_elements(v_plan->'lines') loop
    insert into orders (staff_name, sku, product, qty, order_type, rsp, amount, period, order_group_id, is_topup)
    values (p_staff_name, v_line->>'sku', v_line->>'product', (v_line->>'qty')::int, v_line->>'order_type',
            (v_line->>'rsp')::numeric, (v_line->>'amount')::numeric, v_staff.period, p_group_id,
            (v_line->>'is_topup')::boolean);
  end loop;

  v_balance_after := v_staff.balance;
  if (v_plan->>'allowance_total')::numeric > 0 then
    update staff set balance = balance - (v_plan->>'allowance_total')::numeric
    where id = v_staff.id
    returning balance into v_balance_after;
  end if;

  return v_plan || jsonb_build_object('status', 'ok', 'balance_before', v_staff.balance, 'balance_after', v_balance_after);
end;
$$;

revoke execute on function place_order(text, text, jsonb, text, jsonb) from public, anon;
grant execute on function place_order(text, text, jsonb, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3. Admin: delete order rows and refund in one step
-- ---------------------------------------------------------------------------------------------
-- Refund is computed from the rows this call actually deleted, so calling it twice (double click,
-- retry, two tabs) refunds once: the second call finds nothing left to delete.
create or replace function admin_delete_orders(p_ids bigint[], p_source text) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted int;
  v_refunds jsonb;
  v_refunded numeric := 0;
  r record;
begin
  if not is_admin() then
    raise exception 'NOT_PERMITTED';
  end if;
  if p_source not in ('order_cancelled', 'order_item_removed') then
    raise exception 'BAD_REQUEST: unknown source';
  end if;

  with d as (
    delete from orders where id = any(p_ids)
    returning staff_name, order_type, is_historical, amount
  )
  select (select count(*) from d),
         (select coalesce(jsonb_agg(jsonb_build_object('staff_name', staff_name, 'refund', refund)), '[]'::jsonb)
          from (select staff_name, sum(amount) as refund from d
                where order_type = 'allowance' and not is_historical
                group by staff_name) x)
  into v_deleted, v_refunds;

  for r in select x->>'staff_name' as staff_name, (x->>'refund')::numeric as refund
           from jsonb_array_elements(v_refunds) x
  loop
    insert into staff_audit (staff_name, field, old_value, new_value, changed_by, source)
    select s.name, 'balance', s.balance::text, (s.balance + r.refund)::text, auth.jwt()->>'email', p_source
    from staff s where s.name = r.staff_name;
    update staff set balance = balance + r.refund where name = r.staff_name;
    v_refunded := v_refunded + r.refund;
  end loop;

  return jsonb_build_object('deleted', v_deleted, 'refunded', v_refunded);
end;
$$;

revoke execute on function admin_delete_orders(bigint[], text) from public, anon;
grant execute on function admin_delete_orders(bigint[], text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4. Admin: start a new period atomically
-- ---------------------------------------------------------------------------------------------
create or replace function start_new_period(p_period text) returns int
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_count int;
begin
  if not is_admin() then
    raise exception 'NOT_PERMITTED';
  end if;
  if p_period is null or btrim(p_period) = '' or length(p_period) > 40 then
    raise exception 'BAD_REQUEST: invalid period';
  end if;

  insert into staff_audit (staff_name, field, old_value, new_value, changed_by, source)
  select name, 'balance', balance::text, allowance::text, auth.jwt()->>'email', 'period_reset' from staff
  union all
  select name, 'period', period, btrim(p_period), auth.jwt()->>'email', 'period_reset' from staff where period is distinct from btrim(p_period);

  -- "where true": Supabase's safeupdate guard rejects UPDATE statements with no WHERE clause
  update staff set balance = allowance, period = btrim(p_period) where true;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function start_new_period(text) from public, anon;
grant execute on function start_new_period(text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 5. Defence-in-depth constraints (all existing rows already satisfy these — checked 2026-10-05)
-- ---------------------------------------------------------------------------------------------
alter table orders add constraint orders_qty_positive check (qty > 0);
alter table orders add constraint orders_amounts_nonnegative check (amount >= 0 and rsp >= 0);
alter table orders add constraint orders_group_id_format check (order_group_id is null or order_group_id ~ '^[A-Za-z0-9_.-]{1,100}$');
alter table orders add constraint orders_invoice_url_https check (invoice_url is null or invoice_url ~ '^https://');

-- ---------------------------------------------------------------------------------------------
-- 6. Fixed search_path on the existing SECURITY DEFINER functions
-- ---------------------------------------------------------------------------------------------
alter function staff_guard_update() set search_path = public, pg_temp;
alter function validate_order_amount() set search_path = public, pg_temp;
alter function sync_product_photos_queue() set search_path = public, pg_temp;
alter function sync_product_photos_apply() set search_path = public, pg_temp;
