-- Run this once in the Supabase SQL Editor. Adds:
--   1. staff_audit — a log of every manual allowance/balance change (who, when, before/after),
--      since order-driven balance changes already have their own trail via the orders table.
--   2. A server-side check that every inserted order's rsp/amount actually matches the catalog
--      and the discount rate, so a client bug (or a devtools-poking staff member) can't record a
--      wrong price. Admin is exempt, since historical backfills/manual corrections legitimately
--      need to record a different amount than today's catalog price.
--
-- NOTE: the 0.40 discount rate below must be kept in sync with CONFIG.DISCOUNT_RATE in config.js
-- by hand — there's no single shared source of truth between the client and this trigger.

create table staff_audit (
  id bigint generated always as identity primary key,
  created_at timestamptz default now(),
  staff_name text not null,
  field text not null check (field in ('allowance','balance','period')),
  old_value text,
  new_value text,
  changed_by text not null,
  source text not null -- 'manual_edit' | 'allowance_import' | 'period_reset'
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
  if auth.jwt()->>'email' = 'musa@freedomofmovement.co.za' then
    return new; -- admin can record historical/corrected amounts that won't match today's catalog
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
    v_expected := v_rsp * new.qty; -- allowance rows, and a split order's pay-in rows, are full RSP
  end if;
  if abs(new.amount - v_expected) > 0.01 then
    raise exception 'Amount mismatch for % — submitted % but expected %', new.sku, new.amount, v_expected;
  end if;

  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists validate_order_amount_trigger on orders;
create trigger validate_order_amount_trigger before insert on orders
  for each row execute function validate_order_amount();
