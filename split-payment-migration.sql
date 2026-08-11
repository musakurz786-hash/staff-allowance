-- Run this once in the Supabase SQL Editor to support split Allowance/pay-in purchases.

alter table orders add column if not exists is_topup boolean not null default false;
comment on column orders.is_topup is
  'true when this discount-type row is the pay-in remainder of a split Staff Allowance purchase
   (charged at full RSP, not the 40% staff discount) rather than an ordinary staff-discount
   purchase — still needs Cin7 invoicing like any other discount-type row, just at a different
   rate, so the Discount Report derives each row''s discount amount from rsp*qty - amount rather
   than assuming a flat 40% everywhere.';
