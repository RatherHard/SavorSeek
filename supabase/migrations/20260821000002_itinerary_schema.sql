-- Itinerary aggregate schema for SavorSeek.
-- This migration is forward-only. All aggregate writes are exposed through RPCs
-- in the following migration; base-table DML is revoked from client roles.

create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title varchar(80) not null,
  timezone text not null default 'Asia/Shanghai',
  start_date date not null,
  end_date date not null,
  party_size smallint not null default 1,
  currency_code char(3) not null default 'CNY',
  budget_limit_minor bigint,
  budget_scope text,
  default_travel_mode text not null default 'walking',
  status text not null default 'draft',
  revision bigint not null default 1,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trips_date_range_ck check (end_date >= start_date),
  constraint trips_party_size_ck check (party_size between 1 and 50),
  constraint trips_budget_ck check (budget_limit_minor is null or budget_limit_minor >= 0),
  constraint trips_budget_scope_ck check (
    (budget_limit_minor is null and budget_scope is null)
    or (budget_limit_minor is not null and budget_scope in ('per_person', 'total'))
  ),
  constraint trips_currency_ck check (currency_code ~ '^[A-Z]{3}$'),
  constraint trips_travel_mode_ck check (default_travel_mode in ('walking', 'cycling', 'transit', 'driving')),
  constraint trips_status_ck check (status in ('draft', 'confirmed', 'in_progress', 'completed', 'cancelled')),
  constraint trips_revision_ck check (revision >= 1)
);

create table if not exists public.trip_days (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  local_date date not null,
  available_start_time time,
  available_end_time time,
  budget_limit_minor bigint,
  notes varchar(1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trip_days_trip_date_uq unique (trip_id, local_date),
  constraint trip_days_id_trip_uq unique (id, trip_id),
  constraint trip_days_window_ck check (
    (available_start_time is null and available_end_time is null)
    or (available_start_time is not null and available_end_time is not null and available_end_time > available_start_time)
  ),
  constraint trip_days_budget_ck check (budget_limit_minor is null or budget_limit_minor >= 0)
);

create table if not exists public.trip_items (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  trip_day_id uuid not null,
  item_type text not null,
  place_id uuid,
  title varchar(120) not null,
  planned_start_at timestamptz not null,
  planned_end_at timestamptz not null,
  time_slot text not null default 'flexible',
  position integer not null,
  estimated_cost_min_minor bigint,
  estimated_cost_max_minor bigint,
  notes varchar(1000),
  status text not null default 'planned',
  is_place_locked boolean not null default false,
  is_time_locked boolean not null default false,
  is_order_locked boolean not null default false,
  created_by text not null default 'user',
  source_agent_task_id uuid,
  place_snapshot jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trip_items_day_fk foreign key (trip_day_id, trip_id)
    references public.trip_days (id, trip_id) on delete cascade,
  constraint trip_items_type_ck check (item_type in ('place_visit', 'break')),
  constraint trip_items_title_ck check (char_length(btrim(title)) between 1 and 120),
  constraint trip_items_time_ck check (planned_end_at > planned_start_at),
  constraint trip_items_slot_ck check (time_slot in ('breakfast', 'morning', 'lunch', 'afternoon_tea', 'dinner', 'late_night', 'flexible')),
  constraint trip_items_position_ck check (position >= 0),
  constraint trip_items_cost_min_ck check (estimated_cost_min_minor is null or estimated_cost_min_minor >= 0),
  constraint trip_items_cost_max_ck check (estimated_cost_max_minor is null or estimated_cost_max_minor >= 0),
  constraint trip_items_cost_order_ck check (
    estimated_cost_min_minor is null
    or estimated_cost_max_minor is null
    or estimated_cost_max_minor >= estimated_cost_min_minor
  ),
  constraint trip_items_status_ck check (status in ('planned', 'completed', 'skipped', 'cancelled')),
  constraint trip_items_created_by_ck check (created_by in ('user', 'agent', 'system')),
  constraint trip_items_snapshot_object_ck check (place_snapshot is null or jsonb_typeof(place_snapshot) = 'object')
);

create table if not exists public.trip_idempotency_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  idempotency_key uuid not null,
  request_hash bytea not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (user_id, operation, idempotency_key)
);

create index if not exists trips_user_updated_idx on public.trips (user_id, updated_at desc);
create index if not exists trips_user_status_start_idx on public.trips (user_id, status, start_date);
create index if not exists trip_days_trip_idx on public.trip_days (trip_id);
create index if not exists trip_items_trip_day_start_idx on public.trip_items (trip_id, trip_day_id, planned_start_at);
create index if not exists trip_items_place_idx on public.trip_items (place_id) where place_id is not null;
create unique index if not exists trip_items_active_position_uq
  on public.trip_items (trip_day_id, position) where status <> 'cancelled';
create index if not exists trip_idempotency_created_idx on public.trip_idempotency_keys (created_at);

create or replace function public.set_itinerary_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := clock_timestamp();
  end if;
  return new;
end;
$$;

create or replace function public.validate_trip_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  child_exists boolean;
  money_exists boolean;
begin
  new.title := btrim(new.title);
  if char_length(new.title) < 1 then
    raise exception using errcode = '22023', message = 'trip title must not be blank';
  end if;

  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception using errcode = '22023', message = 'timezone must be a valid IANA timezone';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.user_id is distinct from old.user_id then
      raise exception using errcode = '42501', message = 'trip identity cannot be changed';
    end if;
    if new.revision not in (old.revision, old.revision + 1) then
      raise exception using errcode = '22023', message = 'revision may only stay unchanged or increase by one';
    end if;
    if new.status is distinct from old.status and not (
      (old.status = 'draft' and new.status in ('confirmed', 'cancelled'))
      or (old.status = 'confirmed' and new.status in ('in_progress', 'cancelled'))
      or (old.status = 'in_progress' and new.status in ('completed', 'cancelled'))
    ) then
      raise exception using errcode = '22023', message = 'invalid trip status transition';
    end if;

    select exists (select 1 from public.trip_days where trip_id = old.id) into child_exists;
    if child_exists and new.timezone is distinct from old.timezone then
      raise exception using errcode = '23514', message = 'timezone cannot change after trip days exist';
    end if;
    select exists (
      select 1 from public.trip_days where trip_id = old.id and budget_limit_minor is not null
      union all
      select 1 from public.trip_items where trip_id = old.id
        and (estimated_cost_min_minor is not null or estimated_cost_max_minor is not null)
    ) into money_exists;
    if money_exists and new.currency_code is distinct from old.currency_code then
      raise exception using errcode = '23514', message = 'currency cannot change while aggregate amounts exist';
    end if;
    if exists (
      select 1 from public.trip_days
      where trip_id = old.id and (local_date < new.start_date or local_date > new.end_date)
    ) then
      raise exception using errcode = '23514', message = 'trip date range excludes an existing trip day';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.validate_trip_day_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  parent public.trips%rowtype;
begin
  new.notes := nullif(btrim(new.notes), '');
  select * into parent from public.trips where id = new.trip_id;
  if not found then
    raise exception using errcode = '23503', message = 'trip does not exist';
  end if;
  if new.local_date < parent.start_date or new.local_date > parent.end_date then
    raise exception using errcode = '23514', message = 'trip day is outside the trip date range';
  end if;
  if tg_op = 'UPDATE' and new.trip_id is distinct from old.trip_id then
    raise exception using errcode = '42501', message = 'trip day cannot move between trips';
  end if;
  return new;
end;
$$;

create or replace function public.validate_trip_item_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  parent public.trips%rowtype;
  day_date date;
  snapshot_name text;
  snapshot_version integer;
  latitude numeric;
  longitude numeric;
  coordinate_system text;
begin
  new.title := btrim(new.title);
  new.notes := nullif(btrim(new.notes), '');
  select t.* into parent
  from public.trips t
  join public.trip_days d on d.trip_id = t.id
  where d.id = new.trip_day_id and d.trip_id = new.trip_id;
  if not found then
    raise exception using errcode = '23503', message = 'trip item must reference a day in the same trip';
  end if;
  select local_date into day_date from public.trip_days where id = new.trip_day_id and trip_id = new.trip_id;
  if (new.planned_start_at at time zone parent.timezone)::date <> day_date then
    raise exception using errcode = '23514', message = 'item start date does not match trip day local date';
  end if;

  if new.item_type = 'place_visit' then
    if new.place_snapshot is null or jsonb_typeof(new.place_snapshot) <> 'object' then
      raise exception using errcode = '23514', message = 'place_visit requires a place snapshot';
    end if;
    if tg_op = 'INSERT' and new.place_id is null then
      raise exception using errcode = '23514', message = 'new place_visit requires place_id';
    end if;
    snapshot_version := (new.place_snapshot ->> 'schema_version')::integer;
    snapshot_name := new.place_snapshot ->> 'name';
    if snapshot_version is distinct from 1 or snapshot_name is null or char_length(btrim(snapshot_name)) = 0 then
      raise exception using errcode = '23514', message = 'place snapshot has invalid schema_version or name';
    end if;
    latitude := (new.place_snapshot ->> 'latitude')::numeric;
    longitude := (new.place_snapshot ->> 'longitude')::numeric;
    if (latitude is null) <> (longitude is null) then
      raise exception using errcode = '23514', message = 'snapshot coordinates must be both present or both absent';
    end if;
    if latitude is not null and (latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180) then
      raise exception using errcode = '23514', message = 'snapshot coordinates are out of range';
    end if;
    coordinate_system := new.place_snapshot ->> 'coordinate_system';
    if latitude is not null and coordinate_system not in ('gcj02', 'wgs84') then
      raise exception using errcode = '23514', message = 'snapshot coordinate_system is invalid';
    end if;
  elsif new.place_id is not null or new.place_snapshot is not null then
    raise exception using errcode = '23514', message = 'break items cannot reference a place';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.trip_id is distinct from old.trip_id then
      raise exception using errcode = '42501', message = 'trip item identity cannot be changed';
    end if;
    if current_setting('savorseek.actor', true) = 'agent' and old.is_place_locked and (new.place_id is distinct from old.place_id or new.place_snapshot is distinct from old.place_snapshot) then
      raise exception using errcode = '42501', message = 'place fields are locked';
    end if;
    if current_setting('savorseek.actor', true) = 'agent' and old.is_time_locked and (new.planned_start_at is distinct from old.planned_start_at or new.planned_end_at is distinct from old.planned_end_at or new.time_slot is distinct from old.time_slot) then
      raise exception using errcode = '42501', message = 'time fields are locked';
    end if;
    if current_setting('savorseek.actor', true) = 'agent' and old.is_order_locked and (new.trip_day_id is distinct from old.trip_day_id or new.position is distinct from old.position) then
      raise exception using errcode = '42501', message = 'order fields are locked';
    end if;
    if old.status in ('completed', 'skipped', 'cancelled') and new.status is distinct from old.status then
      raise exception using errcode = '22023', message = 'terminal item status cannot change';
    end if;
  end if;
  return new;
end;
$$;

create trigger trips_validate_before_write before insert or update on public.trips
for each row execute function public.validate_trip_row();
create trigger trip_days_validate_before_write before insert or update on public.trip_days
for each row execute function public.validate_trip_day_row();
create trigger trip_items_validate_before_write before insert or update on public.trip_items
for each row execute function public.validate_trip_item_row();
create trigger trips_updated_at before update on public.trips
for each row execute function public.set_itinerary_updated_at();
create trigger trip_days_updated_at before update on public.trip_days
for each row execute function public.set_itinerary_updated_at();
create trigger trip_items_updated_at before update on public.trip_items
for each row execute function public.set_itinerary_updated_at();

alter table public.trips enable row level security;
alter table public.trip_days enable row level security;
alter table public.trip_items enable row level security;
alter table public.trip_idempotency_keys enable row level security;

create policy trips_select_own on public.trips for select to authenticated
using (user_id = (select auth.uid()));
create policy trip_days_select_own on public.trip_days for select to authenticated
using (exists (select 1 from public.trips t where t.id = trip_days.trip_id and t.user_id = (select auth.uid())));
create policy trip_items_select_own on public.trip_items for select to authenticated
using (exists (select 1 from public.trips t where t.id = trip_items.trip_id and t.user_id = (select auth.uid())));

revoke all on public.trips, public.trip_days, public.trip_items, public.trip_idempotency_keys from anon, authenticated;
grant select on public.trips, public.trip_days, public.trip_items to authenticated;
revoke all on function public.set_itinerary_updated_at() from public, anon, authenticated;
revoke all on function public.validate_trip_row() from public, anon, authenticated;
revoke all on function public.validate_trip_day_row() from public, anon, authenticated;
revoke all on function public.validate_trip_item_row() from public, anon, authenticated;
