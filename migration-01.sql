-- =======================================================================
--  Migration 01 — real flat numbers, owner + tenant details, NID uploads,
--  meter numbers, and the building master meter.
--
--  Run this ONCE in Supabase → SQL Editor, after schema.sql.
--  Safe to run on the placeholder flats you already have — it renames them
--  in place, so nothing that points at a flat gets broken.
-- =====================================================================

-- ---------- 1. NEW COLUMNS -------------------------------------------

alter table public.flats
  add column if not exists block           text,
  add column if not exists flat_number     integer,
  add column if not exists meter_no        text,
  add column if not exists is_common       boolean not null default false,
  add column if not exists owner_nid_path  text,
  add column if not exists tenant_name     text,
  add column if not exists tenant_phone    text,
  add column if not exists tenant_nid_path text;

comment on column public.flats.is_common is
  'true for the building master meter (stairs, lift, garage), not a residence';

-- ---------- 2. RENAME THE 30 FLATS -----------------------------------
-- A1-A8, B1-B8, C1-C7, D1-D7, displayed as 1A ... 8A, 1B ... 7D

with target as (
  select row_number() over (order by block_order, num) as rn, block, num
  from (
    select 'A' as block, 1 as block_order, g as num from generate_series(1,8) g
    union all select 'B', 2, g from generate_series(1,8) g
    union all select 'C', 3, g from generate_series(1,7) g
    union all select 'D', 4, g from generate_series(1,7) g
  ) x
),
present as (
  select id, row_number() over (order by id) as rn
  from public.flats
  where is_common = false
)
update public.flats f
set block       = t.block,
    flat_number = t.num,
    flat_no     = t.num::text || t.block
from target t
join present p on p.rn = t.rn
where f.id = p.id;

-- ---------- 3. THE MASTER METER --------------------------------------
-- 31st meter: stairs, lift and garage. Not a residence, so it carries no
-- owner or tenant — the committee settles it from building funds.

insert into public.flats (flat_no, block, flat_number, is_common, owner_name)
values ('Master meter', 'Z', 999, true, 'Stairs, lift and garage')
on conflict (flat_no) do nothing;

-- ---------- 4. RESIDENTS MAY MAINTAIN THEIR OWN DETAILS --------------

drop policy if exists flats_update_own on public.flats;
create policy flats_update_own on public.flats for update to authenticated
  using      (id = public.my_flat_id())
  with check (id = public.my_flat_id());

-- but only the committee may change the identity of the flat itself
create or replace function public.guard_flat_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    if new.flat_no     is distinct from old.flat_no
    or new.block       is distinct from old.block
    or new.flat_number is distinct from old.flat_number
    or new.meter_no    is distinct from old.meter_no
    or new.is_common   is distinct from old.is_common then
      raise exception 'Only the committee can change the flat number or meter number.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_flat_update on public.flats;
create trigger trg_guard_flat_update
  before update on public.flats
  for each row execute function public.guard_flat_update();

-- ---------- 5. PRIVATE BUCKET FOR NID COPIES -------------------------
-- Separate from bill receipts, and readable ONLY by that flat and the
-- committee. Other residents can see names and phone numbers, never NIDs.

insert into storage.buckets (id, name, public)
values ('documents','documents', false)
on conflict (id) do nothing;

drop policy if exists documents_read   on storage.objects;
drop policy if exists documents_insert on storage.objects;
drop policy if exists documents_update on storage.objects;
drop policy if exists documents_delete on storage.objects;

create policy documents_read on storage.objects for select to authenticated
using (
  bucket_id = 'documents'
  and (public.is_admin() or (storage.foldername(name))[1] = public.my_flat_id()::text)
);

create policy documents_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'documents'
  and (public.is_admin() or (storage.foldername(name))[1] = public.my_flat_id()::text)
);

create policy documents_update on storage.objects for update to authenticated
using (
  bucket_id = 'documents'
  and (public.is_admin() or (storage.foldername(name))[1] = public.my_flat_id()::text)
);

create policy documents_delete on storage.objects for delete to authenticated
using (bucket_id = 'documents' and public.is_admin());

-- ---------- 6. BILL RUN, NOW AWARE OF THE MASTER METER ---------------
-- The master meter usually costs a different amount from a flat, so it
-- takes its own figure. Leave it blank to skip the master meter entirely.

drop function if exists public.create_period_bills(text, numeric);

create or replace function public.create_period_bills(
  p_period text,
  p_amount numeric,
  p_common_amount numeric default null
)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then
    raise exception 'Only the committee can open a billing month.';
  end if;

  insert into bills (flat_id, period, amount)
  select id, p_period, p_amount from flats where is_common = false
  on conflict (flat_id, period) do nothing;
  get diagnostics n = row_count;

  if p_common_amount is not null then
    insert into bills (flat_id, period, amount)
    select id, p_period, p_common_amount from flats where is_common = true
    on conflict (flat_id, period) do nothing;
  end if;

  return n;
end $$;

grant execute on function public.create_period_bills(text, numeric, numeric) to authenticated;

-- ---------- 7. CHECK ------------------------------------------------
-- Should list 1A..8A, 1B..8B, 1C..7C, 1D..7D, then Master meter.

select flat_no, block, flat_number, meter_no
from public.flats
order by is_common, block, flat_number;
