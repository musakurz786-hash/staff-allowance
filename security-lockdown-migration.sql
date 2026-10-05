-- Security fix, part 2 of 2 (2026-10-05). Run in the Supabase SQL Editor ONLY AFTER the new
-- index.html (which checks out via place_order()) is live. Requires security-fix-migration.sql.
--
-- Closes the direct-write paths the old page used, so the only way a non-admin can create orders
-- or change a balance is place_order() — which prices from the catalog, checks the balance and
-- deducts in one locked transaction. Anyone still on a cached old page gets an error on checkout
-- and just needs to refresh.

-- orders: staff can no longer INSERT directly (that let them write allowance orders that were
-- never deducted, or set admin-only columns like invoiced / invoice_url / is_historical).
drop policy if exists "insert own orders, admin inserts any" on orders;
create policy "admin inserts orders" on orders for insert
  with check (is_admin());

-- staff: only admin updates rows directly; staff balances only move via place_order().
drop policy if exists "own row balance update, admin updates all" on staff;
create policy "admin updates staff" on staff for update
  using (is_admin())
  with check (is_admin());

-- adjust_staff_balance: admin only from now on.
create or replace function adjust_staff_balance(p_name text, p_delta numeric) returns numeric
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_new numeric;
begin
  if not is_admin() then
    raise exception 'Not permitted to adjust this balance';
  end if;
  update staff set balance = balance + p_delta where name = p_name returning balance into v_new;
  if not found then
    raise exception 'Staff not found: %', p_name;
  end if;
  return v_new;
end;
$$;

revoke execute on function adjust_staff_balance(text, numeric) from public, anon;
grant execute on function adjust_staff_balance(text, numeric) to authenticated;

-- trigger functions only ever run as triggers (EXECUTE isn't checked when a trigger fires — verified
-- 2026-10-05); this just stops them being exposed as /rest/v1/rpc endpoints
revoke execute on function staff_guard_update() from public, anon, authenticated;
revoke execute on function validate_order_amount() from public, anon, authenticated;
