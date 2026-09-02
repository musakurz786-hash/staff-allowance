-- Run this once in the Supabase SQL Editor. Fixes three related issues found in this session's
-- second code review pass:
--
-- 1. Every balance-changing action (order checkout, admin edits, refunds) did a
--    GET-current-value-then-PATCH-absolute-value from JavaScript — a classic read/write race:
--    two concurrent writes can silently clobber each other with no error. adjust_staff_balance()
--    below does the increment atomically inside a single UPDATE statement, which Postgres
--    guarantees is race-safe under concurrent access, regardless of how stale the caller's own
--    view of the "current" balance was.
--
-- 2. Nothing stopped a staff member from bypassing the app entirely and PATCHing their own
--    balance UP via a direct API call (RLS and the existing trigger both allowed it, and it left
--    no record in staff_audit). staff_guard_update() now blocks a non-admin from ever increasing
--    their own balance — only admin, or the atomic decrement a real purchase performs, can do that.
--
-- 3. The order price-validation trigger's admin exemption relies on auth.jwt(), which is empty
--    outside a PostgREST-authenticated request — so a legitimate historical backfill run directly
--    in the SQL Editor would have been rejected by the same strict check as a normal order. Now
--    also exempts any request with no JWT context at all (a direct DB session), since a genuine
--    anonymous/staff request coming through the app's public API always has *some* JWT set.

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

create or replace function staff_guard_update() returns trigger as $$
begin
  if auth.jwt()->>'email' = 'musa@freedomofmovement.co.za' then
    return new;
  end if;
  if old.email is distinct from new.email
     or old.name is distinct from new.name
     or old.allowance is distinct from new.allowance
     or old.period is distinct from new.period then
    raise exception 'Not permitted to modify this field';
  end if;
  if new.balance > old.balance then
    raise exception 'Not permitted to increase your own balance';
  end if;
  return new;
end;
$$ language plpgsql security definer;

create or replace function validate_order_amount() returns trigger as $$
declare
  v_rsp numeric;
  v_expected numeric;
begin
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
    v_expected := round(v_rsp * new.qty * (1 - 0.40), 2);
  else
    v_expected := v_rsp * new.qty;
  end if;
  if abs(new.amount - v_expected) > 0.01 then
    raise exception 'Amount mismatch for % — submitted % but expected %', new.sku, new.amount, v_expected;
  end if;

  return new;
end;
$$ language plpgsql security definer;
