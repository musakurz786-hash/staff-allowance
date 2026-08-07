-- Run this ONCE in the Supabase SQL Editor on the live project to switch from the old
-- "anyone with the link can read/write anything" policies to real per-staff access control.
-- Safe to run even if some of these policies don't exist yet (IF EXISTS guards each drop).
-- See schema.sql for the full, documented version of what this leaves in place.

drop policy if exists "anon read staff" on staff;
drop policy if exists "anon insert staff" on staff;
drop policy if exists "anon update staff" on staff;
drop policy if exists "anon delete staff" on staff;
drop policy if exists "anon read products" on products;
drop policy if exists "anon write products" on products;
drop policy if exists "anon read orders" on orders;
drop policy if exists "anon insert orders" on orders;
drop policy if exists "anon update orders" on orders;
drop policy if exists "anon delete orders" on orders;
drop policy if exists "anon upload invoices" on storage.objects;

create policy "read own staff row, admin reads all" on staff for select
  using (email = auth.jwt()->>'email' or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "admin insert staff" on staff for insert
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "admin delete staff" on staff for delete
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "own row balance update, admin updates all" on staff for update
  using (email = auth.jwt()->>'email' or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (email = auth.jwt()->>'email' or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

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
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists staff_guard_update_trigger on staff;
create trigger staff_guard_update_trigger before update on staff
  for each row execute function staff_guard_update();

create policy "any logged-in user reads products" on products for select
  using (auth.role() = 'authenticated');
create policy "admin writes products" on products for all
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

create policy "read own orders, admin reads all" on orders for select
  using (
    staff_name = (select name from staff where email = auth.jwt()->>'email')
    or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za'
  );
create policy "insert own orders, admin inserts any" on orders for insert
  with check (
    staff_name = (select name from staff where email = auth.jwt()->>'email')
    or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za'
  );
create policy "admin updates orders" on orders for update
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za')
  with check (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
create policy "admin deletes orders" on orders for delete
  using (auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');

create policy "admin uploads invoices" on storage.objects for insert
  with check (bucket_id = 'invoices' and auth.jwt()->>'email' = 'musa@freedomofmovement.co.za');
-- "anon read invoices" policy already exists and is unchanged — bucket is Public anyway, so this
-- only governs API-level listing, not the plain PDF links used in emails.
