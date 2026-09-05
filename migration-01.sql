-- =====================================================================
--  Migration 14 — service charges
--
--  Run ONCE in Supabase → SQL Editor, after migration-13.sql.
--
--  Separate from electricity bills, and works differently:
--    · the committee assigns amounts; residents do not enter anything
--    · a charge is broken into components (guard salary, generator, ...)
--    · assigned fresh each month — nothing carries over on its own
--    · the committee marks it paid; there is no upload or verification,
--      because this is normally settled in cash or bKash
--
--  Every mark-paid is recorded with who did it. This is money changing
--  hands with no receipt, so the log is the only record there is.
-- =====================================================================

-- ---------- 1. THE COMPONENT LIST ------------------------------------

create table if not exists public.service_components (
  id         bigint generated always as identity primary key,
  name       text not null unique,
  sort_order integer default 0,
  active     boolean not null default true
);

alter table public.service_components enable row level security;

drop policy if exists sc_components_read  on public.service_components;
drop policy if exists sc_components_write on public.service_components;

create policy sc_components_read on public.service_components
  for select to authenticated using (true);
create policy sc_components_write on public.service_components
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.service_components (name, sort_order) values
  ('Guard salary', 1),
  ('Generator',    2),
  ('Electricity',  3),
  ('Water bill',   4),
  ('Others',       5)
on conflict (name) do nothing;

-- ---------- 2. THE CHARGES -------------------------------------------
-- lines is a snapshot: [{"name":"Guard salary","amount":500}, ...]
-- Storing the component NAME rather than only an id means renaming a
-- component later does not rewrite what a flat was charged in the past.

create table if not exists public.service_charges (
  id         bigint generated always as identity primary key,
  flat_id    bigint not null references public.flats(id) on delete cascade,
  period     text not null,                          -- 'YYYY-MM'
  lines      jsonb not null default '[]'::jsonb,
  total      numeric(12,2) not null default 0,
  status     text not null default 'unpaid' check (status in ('unpaid','paid')),
  paid_at    timestamptz,
  paid_by    uuid references auth.users(id) on delete set null,
  paid_name  text,
  method     text,                                   -- cash, bKash, bank...
  note       text,
  updated_at timestamptz,
  unique (flat_id, period)
);

create index if not exists sc_period_idx on public.service_charges (period);

alter table public.service_charges enable row level security;

-- Status and amounts are visible to everyone, exactly like electricity —
-- that transparency is the point of the board. Only the committee writes.
drop policy if exists sc_read  on public.service_charges;
drop policy if exists sc_write on public.service_charges;

create policy sc_read on public.service_charges
  for select to authenticated using (true);
create policy sc_write on public.service_charges
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- 3. TOTAL IS ALWAYS THE SUM OF THE LINES ------------------

create or replace function public.calc_service_total()
returns trigger language plpgsql as $$
begin
  new.total := coalesce((
    select sum((x->>'amount')::numeric)
    from jsonb_array_elements(coalesce(new.lines, '[]'::jsonb)) x
    where (x->>'amount') is not null
  ), 0);
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_calc_service_total on public.service_charges;
create trigger trg_calc_service_total
  before insert or update on public.service_charges
  for each row execute function public.calc_service_total();

-- ---------- 4. AUDIT --------------------------------------------------

create table if not exists public.service_events (
  id         bigint generated always as identity primary key,
  charge_id  bigint not null references public.service_charges(id) on delete cascade,
  flat_id    bigint not null references public.flats(id) on delete cascade,
  actor      uuid references auth.users(id) on delete set null,
  actor_name text,
  action     text not null,          -- 'assigned', 'amount changed', 'marked paid', 'reopened'
  total      numeric(12,2),
  note       text,
  created_at timestamptz not null default now()
);

create index if not exists sc_events_idx on public.service_events (flat_id, created_at desc);

alter table public.service_events enable row level security;

drop policy if exists sc_events_read on public.service_events;
create policy sc_events_read on public.service_events for select to authenticated
  using (public.is_admin() or flat_id = public.my_flat_id());
-- no write policies: only the trigger below writes, as security definer

create or replace function public.log_service_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare who text; act text;
begin
  select coalesce(full_name, email) into who from profiles where id = auth.uid();
  who := coalesce(who, 'Supabase dashboard');

  if TG_OP = 'INSERT' then
    act := 'assigned';
  elsif new.status is distinct from old.status then
    act := case when new.status = 'paid' then 'marked paid' else 'reopened' end;
  elsif new.total is distinct from old.total then
    act := 'amount changed';
  else
    return new;
  end if;

  insert into service_events (charge_id, flat_id, actor, actor_name, action, total, note)
  values (new.id, new.flat_id, auth.uid(), who, act, new.total, new.note);
  return new;
end $$;

drop trigger if exists trg_log_service_event on public.service_charges;
create trigger trg_log_service_event
  after insert or update on public.service_charges
  for each row execute function public.log_service_event();

-- ---------- 5. ASSIGN TO MANY FLATS AT ONCE --------------------------
-- The committee picks the flats that share a rate and applies one set of
-- amounts to all of them. A charge already marked paid is left alone, so
-- re-running cannot quietly alter what someone has already settled.

create or replace function public.assign_service_charges(
  p_period   text,
  p_flat_ids bigint[],
  p_lines    jsonb
)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then
    raise exception 'Only the committee can assign service charges.';
  end if;
  if p_flat_ids is null or array_length(p_flat_ids, 1) is null then
    raise exception 'No flats were selected.';
  end if;

  insert into service_charges (flat_id, period, lines)
  select unnest(p_flat_ids), p_period, coalesce(p_lines, '[]'::jsonb)
  on conflict (flat_id, period) do update
    set lines = excluded.lines
    where service_charges.status <> 'paid';

  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function public.assign_service_charges(text, bigint[], jsonb) to authenticated;

-- ---------- 6. MONTHLY SUMMARY ---------------------------------------

create or replace function public.service_totals(p_period text)
returns table (assigned integer, paid integer, billed numeric, collected numeric)
language sql stable security definer set search_path = public as $$
  select
    count(*)::integer,
    count(*) filter (where status = 'paid')::integer,
    coalesce(sum(total), 0),
    coalesce(sum(total) filter (where status = 'paid'), 0)
  from service_charges where period = p_period;
$$;

grant execute on function public.service_totals(text) to authenticated;

-- ---------- 7. CHECK -------------------------------------------------

select 'components' as item, count(*)::text as value from public.service_components
union all
select 'charges', count(*)::text from public.service_charges;
