-- Run this once in the Supabase SQL Editor. Adds an image_url column so the order screen can show
-- a real product photo instead of just a category icon placeholder. Populated via the new "Import
-- Product Photos" button in Admin, which fetches directly from freedomofmovement.co.za's public
-- Shopify product feed and matches by SKU — no export/upload needed for this one, unlike the
-- pricing import.

alter table products add column if not exists image_url text;
