-- 行程页面整合：节点编辑、行程生命周期，以及移除节点级取消状态。
--
-- 本迁移必须在 20260824000010_update_trip_item.sql 之后执行。
-- 仓库中的迁移不会自动上库；应用后请执行
-- supabase/snippets/verify_trip_page_consolidation.sql 对账。

-- ---------------------------------------------------------------------------
-- 1. 先移除节点级取消 RPC，并把已有取消项恢复为 planned。
-- ---------------------------------------------------------------------------
-- cancelled 只是用户当前不打算去的意图，不是节点生命周期事实。保留节点并恢复
-- 为 planned，避免本次 schema 收窄静默销毁用户可能还想整理的内容。
drop function if exists public.cancel_trip_item(uuid, bigint, uuid, uuid);
drop function if exists public.restore_trip_item(uuid, bigint, uuid, uuid);
drop function if exists public.batch_cancel_trip_items(uuid, bigint, uuid, uuid[]);

drop index if exists public.trip_items_active_position_uq;

-- 取消项追加到当天已有最大 position 之后；同一批按开始时间稳定排序。
with cancelled_items as (
  select
    id,
    trip_day_id,
    row_number() over (
      partition by trip_day_id
      order by planned_start_at, id
    ) - 1 as item_offset
  from public.trip_items
  where status = 'cancelled'
), day_positions as (
  select
    trip_day_id,
    coalesce(max(position) filter (where status <> 'cancelled'), -1) as last_position
  from public.trip_items
  group by trip_day_id
)
update public.trip_items as item
set
  status = 'planned',
  position = positions.last_position + cancelled.item_offset + 1
from cancelled_items as cancelled
join day_positions as positions using (trip_day_id)
where item.id = cancelled.id;

alter table public.trip_items
  drop constraint if exists trip_items_status_ck;
alter table public.trip_items
  add constraint trip_items_status_ck
  check (status in ('planned', 'completed', 'skipped'));

create unique index trip_items_active_position_uq
  on public.trip_items (trip_day_id, position);

-- ---------------------------------------------------------------------------
-- 2. 收紧节点 trigger：completed / skipped 是唯一的节点终态。
-- ---------------------------------------------------------------------------
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
  select local_date into day_date
  from public.trip_days
  where id = new.trip_day_id and trip_id = new.trip_id;
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
    if snapshot_version is distinct from 1
      or snapshot_name is null
      or char_length(btrim(snapshot_name)) = 0 then
      raise exception using errcode = '23514',
        message = 'place snapshot has invalid schema_version or name';
    end if;
    latitude := (new.place_snapshot ->> 'latitude')::numeric;
    longitude := (new.place_snapshot ->> 'longitude')::numeric;
    if (latitude is null) <> (longitude is null) then
      raise exception using errcode = '23514',
        message = 'snapshot coordinates must be both present or both absent';
    end if;
    if latitude is not null
      and (latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180) then
      raise exception using errcode = '23514', message = 'snapshot coordinates are out of range';
    end if;
    coordinate_system := new.place_snapshot ->> 'coordinate_system';
    if latitude is not null and coordinate_system not in ('gcj02', 'wgs84') then
      raise exception using errcode = '23514',
        message = 'snapshot coordinate_system is invalid';
    end if;
  elsif new.place_id is not null or new.place_snapshot is not null then
    raise exception using errcode = '23514', message = 'break items cannot reference a place';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.trip_id is distinct from old.trip_id then
      raise exception using errcode = '42501', message = 'trip item identity cannot be changed';
    end if;
    if current_setting('savorseek.actor', true) = 'agent'
      and old.is_place_locked
      and (new.place_id is distinct from old.place_id
        or new.place_snapshot is distinct from old.place_snapshot) then
      raise exception using errcode = '42501', message = 'place fields are locked';
    end if;
    if current_setting('savorseek.actor', true) = 'agent'
      and old.is_time_locked
      and (new.planned_start_at is distinct from old.planned_start_at
        or new.planned_end_at is distinct from old.planned_end_at
        or new.time_slot is distinct from old.time_slot) then
      raise exception using errcode = '42501', message = 'time fields are locked';
    end if;
    if current_setting('savorseek.actor', true) = 'agent'
      and old.is_order_locked
      and (new.trip_day_id is distinct from old.trip_day_id
        or new.position is distinct from old.position) then
      raise exception using errcode = '42501', message = 'order fields are locked';
    end if;
    if old.status in ('completed', 'skipped')
      and new.status is distinct from old.status then
      raise exception using errcode = '22023', message = 'terminal item status cannot change';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. 行程状态机：接通当前需要的完成路径。
-- ---------------------------------------------------------------------------
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
      raise exception using errcode = '22023',
        message = 'revision may only stay unchanged or increase by one';
    end if;
    if new.status is distinct from old.status and not (
      (old.status = 'draft' and new.status in ('confirmed', 'completed', 'cancelled'))
      or (old.status = 'confirmed' and new.status in ('in_progress', 'completed', 'cancelled'))
      or (old.status = 'in_progress' and new.status in ('completed', 'cancelled'))
    ) then
      raise exception using errcode = '22023', message = 'invalid trip status transition';
    end if;

    select exists (
      select 1 from public.trip_days where trip_id = old.id
    ) into child_exists;
    if child_exists
      and new.timezone is distinct from old.timezone
      and coalesce(current_setting('savorseek.timezone_migration', true), '') <> 'on' then
      raise exception using errcode = '23514',
        message = 'timezone cannot change after trip days exist';
    end if;
    select exists (
      select 1 from public.trip_days
      where trip_id = old.id and budget_limit_minor is not null
      union all
      select 1 from public.trip_items
      where trip_id = old.id
        and (estimated_cost_min_minor is not null or estimated_cost_max_minor is not null)
    ) into money_exists;
    if money_exists and new.currency_code is distinct from old.currency_code then
      raise exception using errcode = '23514',
        message = 'currency cannot change while aggregate amounts exist';
    end if;
    if exists (
      select 1 from public.trip_days
      where trip_id = old.id
        and (local_date < new.start_date or local_date > new.end_date)
    ) then
      raise exception using errcode = '23514',
        message = 'trip date range excludes an existing trip day';
    end if;
  end if;
  return new;
end;
$$;

-- 所有节点写 RPC 在锁定父行程后调用此函数。completed 是行程级只读终态；cancelled
-- 不拦截，因为取消行程后仍允许用户整理记录。
create or replace function public.assert_trip_writable(p_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  trip_status text;
begin
  select status into trip_status
  from public.trips
  where id = p_trip_id;
  if trip_status = 'completed' then
    raise exception using errcode = 'P0003',
      message = 'trip is completed and read-only';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. 节点添加：保留原 RPC，接入行程只读守卫。
-- ---------------------------------------------------------------------------
create or replace function public.add_trip_item(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_day_id uuid,
  p_item_type text,
  p_place_id uuid,
  p_title varchar(120),
  p_planned_start_at timestamptz,
  p_planned_end_at timestamptz,
  p_time_slot text default 'flexible',
  p_position integer default 0,
  p_estimated_cost_min_minor bigint default null,
  p_estimated_cost_max_minor bigint default null,
  p_notes varchar(1000) default null,
  p_place_snapshot jsonb default null
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  created public.trip_items%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'trip_day_id', p_trip_day_id,
    'item_type', p_item_type,
    'place_id', p_place_id,
    'title', p_title,
    'planned_start_at', p_planned_start_at,
    'planned_end_at', p_planned_end_at,
    'time_slot', p_time_slot,
    'position', p_position,
    'estimated_cost_min_minor', p_estimated_cost_min_minor,
    'estimated_cost_max_minor', p_estimated_cost_max_minor,
    'notes', p_notes,
    'place_snapshot', p_place_snapshot
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'add_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  insert into public.trip_items(
    trip_id,
    trip_day_id,
    item_type,
    place_id,
    title,
    planned_start_at,
    planned_end_at,
    time_slot,
    position,
    estimated_cost_min_minor,
    estimated_cost_max_minor,
    notes,
    place_snapshot
  ) values (
    p_trip_id,
    p_trip_day_id,
    p_item_type,
    p_place_id,
    p_title,
    p_planned_start_at,
    p_planned_end_at,
    p_time_slot,
    p_position,
    p_estimated_cost_min_minor,
    p_estimated_cost_max_minor,
    p_notes,
    p_place_snapshot
  ) returning * into created;

  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'trip_item', to_jsonb(created),
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'add_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. 合并节点编辑：标题、备注、日期、时间、时长一次提交。
-- ---------------------------------------------------------------------------
create or replace function public.edit_trip_item(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_item_id uuid,
  p_title text,
  p_notes text,
  p_trip_day_id uuid,
  p_planned_start_at timestamptz,
  p_planned_end_at timestamptz,
  p_time_slot text
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  existing public.trip_items%rowtype;
  updated public.trip_items%rowtype;
  clean_title text;
  clean_notes text;
  target_position integer;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  clean_title := btrim(coalesce(p_title, ''));
  clean_notes := nullif(btrim(coalesce(p_notes, '')), '');
  if char_length(clean_title) < 1 then
    raise exception using errcode = '22023',
      message = 'trip item title must not be blank';
  end if;
  if char_length(clean_title) > 120 then
    raise exception using errcode = '22023',
      message = 'trip item title must not exceed 120 characters';
  end if;
  if clean_notes is not null and char_length(clean_notes) > 1000 then
    raise exception using errcode = '22023',
      message = 'trip item notes must not exceed 1000 characters';
  end if;

  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'trip_item_id', p_trip_item_id,
    'title', clean_title,
    'notes', clean_notes,
    'trip_day_id', p_trip_day_id,
    'planned_start_at', p_planned_start_at,
    'planned_end_at', p_planned_end_at,
    'time_slot', p_time_slot
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'edit_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  select * into existing
  from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  if existing.status in ('completed', 'skipped') then
    raise exception using errcode = '22023',
      message = 'a completed or skipped item cannot be edited';
  end if;
  if not exists (
    select 1 from public.trip_days
    where id = p_trip_day_id and trip_id = p_trip_id
  ) then
    raise exception using errcode = '22023',
      message = 'target trip day does not belong to this trip';
  end if;

  if p_trip_day_id = existing.trip_day_id then
    target_position := existing.position;
  else
    select coalesce(max(position) + 1, 0) into target_position
    from public.trip_items
    where trip_day_id = p_trip_day_id;
  end if;

  update public.trip_items
  set
    title = clean_title,
    notes = clean_notes,
    trip_day_id = p_trip_day_id,
    planned_start_at = p_planned_start_at,
    planned_end_at = p_planned_end_at,
    time_slot = p_time_slot,
    position = target_position
  where id = p_trip_item_id
  returning * into updated;

  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'trip_item', to_jsonb(updated),
    'trip_item_id', p_trip_item_id,
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'edit_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. 改期、编辑、删除与批量删除接入只读守卫。
-- ---------------------------------------------------------------------------
create or replace function public.reschedule_trip_item(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_item_id uuid,
  p_trip_day_id uuid,
  p_planned_start_at timestamptz,
  p_planned_end_at timestamptz,
  p_time_slot text
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  existing public.trip_items%rowtype;
  target_position integer;
  updated public.trip_items%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'trip_item_id', p_trip_item_id,
    'trip_day_id', p_trip_day_id,
    'planned_start_at', p_planned_start_at,
    'planned_end_at', p_planned_end_at,
    'time_slot', p_time_slot
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'reschedule_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  select * into existing
  from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  if existing.status in ('completed', 'skipped') then
    raise exception using errcode = '22023',
      message = 'cannot reschedule an item in a terminal state';
  end if;
  if not exists (
    select 1 from public.trip_days
    where id = p_trip_day_id and trip_id = p_trip_id
  ) then
    raise exception using errcode = '22023',
      message = 'target trip day does not belong to this trip';
  end if;

  if p_trip_day_id = existing.trip_day_id then
    target_position := existing.position;
  else
    select coalesce(max(position) + 1, 0) into target_position
    from public.trip_items
    where trip_day_id = p_trip_day_id;
  end if;

  update public.trip_items set
    trip_day_id = p_trip_day_id,
    planned_start_at = p_planned_start_at,
    planned_end_at = p_planned_end_at,
    time_slot = p_time_slot,
    position = target_position
  where id = p_trip_item_id
  returning * into updated;

  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'trip_item', to_jsonb(updated),
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'reschedule_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

create or replace function public.update_trip_item(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_item_id uuid,
  p_title text,
  p_notes text
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  existing public.trip_items%rowtype;
  clean_title text;
  clean_notes text;
  updated public.trip_items%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  clean_title := btrim(coalesce(p_title, ''));
  clean_notes := nullif(btrim(coalesce(p_notes, '')), '');
  if char_length(clean_title) < 1 then
    raise exception using errcode = '22023', message = 'trip item title must not be blank';
  end if;
  if char_length(clean_title) > 120 then
    raise exception using errcode = '22023',
      message = 'trip item title must not exceed 120 characters';
  end if;
  if clean_notes is not null and char_length(clean_notes) > 1000 then
    raise exception using errcode = '22023',
      message = 'trip item notes must not exceed 1000 characters';
  end if;

  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'trip_item_id', p_trip_item_id,
    'title', clean_title,
    'notes', clean_notes
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'update_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  select * into existing
  from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  if existing.status in ('completed', 'skipped') then
    raise exception using errcode = '22023',
      message = 'a completed or skipped item cannot be edited';
  end if;

  update public.trip_items
  set title = clean_title, notes = clean_notes
  where id = p_trip_item_id
  returning * into updated;
  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'trip_item', to_jsonb(updated),
    'trip_item_id', p_trip_item_id,
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'update_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

create or replace function public.delete_trip_item(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_item_id uuid
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  existing public.trip_items%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id, 'trip_item_id', p_trip_item_id
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'delete_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  select * into existing
  from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  if existing.status in ('completed', 'skipped') then
    raise exception using errcode = '22023',
      message = 'a completed or skipped item cannot be deleted';
  end if;

  delete from public.trip_items where id = p_trip_item_id;
  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'deleted_trip_item_id', p_trip_item_id,
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'delete_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

create or replace function public.batch_delete_trip_items(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_item_ids uuid[]
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  distinct_ids uuid[];
  found_count integer;
  blocked_count integer;
  deleted_count integer;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_trip_item_ids is null or cardinality(p_trip_item_ids) = 0 then
    raise exception using errcode = '22023',
      message = 'at least one trip item id is required';
  end if;

  select array_agg(distinct id) into distinct_ids
  from unnest(p_trip_item_ids) as id;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'trip_item_ids', (
      select jsonb_agg(id order by id) from unnest(distinct_ids) as id
    )
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'batch_delete_trip_items', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  select count(*) into found_count
  from public.trip_items
  where trip_id = p_trip_id and id = any(distinct_ids);
  if found_count <> cardinality(distinct_ids) then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  select count(*) into blocked_count
  from public.trip_items
  where trip_id = p_trip_id
    and id = any(distinct_ids)
    and status in ('completed', 'skipped');
  if blocked_count > 0 then
    raise exception using errcode = '22023',
      message = 'a completed or skipped item cannot be deleted';
  end if;

  delete from public.trip_items
  where trip_id = p_trip_id and id = any(distinct_ids);
  get diagnostics deleted_count = row_count;
  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'deleted_trip_item_ids', to_jsonb(distinct_ids),
    'deleted_count', deleted_count,
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'batch_delete_trip_items', p_idempotency_key, result
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. 行程生命周期。
-- ---------------------------------------------------------------------------
create or replace function public.complete_trip(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  updated public.trips%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object('trip_id', p_trip_id)::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'complete_trip', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  if trip_row.status in ('completed', 'cancelled') then
    raise exception using errcode = '22023',
      message = 'only an active trip can be completed';
  end if;

  update public.trips
  set status = 'completed', revision = revision + 1
  where id = p_trip_id
  returning * into updated;
  result := jsonb_build_object(
    'trip', to_jsonb(updated),
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'complete_trip', p_idempotency_key, result
  );
  return result;
end;
$$;

create or replace function public.cancel_trip(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  updated public.trips%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object('trip_id', p_trip_id)::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'cancel_trip', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  if trip_row.status in ('completed', 'cancelled') then
    raise exception using errcode = '22023',
      message = 'only an active trip can be cancelled';
  end if;

  update public.trips
  set status = 'cancelled', revision = revision + 1
  where id = p_trip_id
  returning * into updated;
  result := jsonb_build_object(
    'trip', to_jsonb(updated),
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'cancel_trip', p_idempotency_key, result
  );
  return result;
end;
$$;

create or replace function public.delete_trip(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  deleted_count integer;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object('trip_id', p_trip_id)::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'delete_trip', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  delete from public.trips where id = p_trip_id and user_id = actor;
  get diagnostics deleted_count = row_count;
  result := jsonb_build_object(
    'deleted_trip_id', p_trip_id,
    'deleted_count', deleted_count
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'delete_trip', p_idempotency_key, result
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 授权：新 RPC 只允许 authenticated 调用；内部 helper 不暴露给客户端。
-- ---------------------------------------------------------------------------
revoke all on function public.assert_trip_writable(uuid)
  from public, anon, authenticated;

revoke all on function public.add_trip_item(
  uuid, bigint, uuid, uuid, text, uuid, varchar, timestamptz, timestamptz,
  text, integer, bigint, bigint, varchar, jsonb
) from public, anon, authenticated;
revoke all on function public.edit_trip_item(
  uuid, bigint, uuid, uuid, text, text, uuid, timestamptz, timestamptz, text
) from public, anon, authenticated;
revoke all on function public.reschedule_trip_item(
  uuid, bigint, uuid, uuid, uuid, timestamptz, timestamptz, text
) from public, anon, authenticated;
revoke all on function public.update_trip_item(uuid, bigint, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.delete_trip_item(uuid, bigint, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.batch_delete_trip_items(uuid, bigint, uuid, uuid[])
  from public, anon, authenticated;
revoke all on function public.complete_trip(uuid, bigint, uuid)
  from public, anon, authenticated;
revoke all on function public.cancel_trip(uuid, bigint, uuid)
  from public, anon, authenticated;
revoke all on function public.delete_trip(uuid, bigint, uuid)
  from public, anon, authenticated;

grant execute on function public.add_trip_item(
  uuid, bigint, uuid, uuid, text, uuid, varchar, timestamptz, timestamptz,
  text, integer, bigint, bigint, varchar, jsonb
) to authenticated;
grant execute on function public.edit_trip_item(
  uuid, bigint, uuid, uuid, text, text, uuid, timestamptz, timestamptz, text
) to authenticated;
grant execute on function public.reschedule_trip_item(
  uuid, bigint, uuid, uuid, uuid, timestamptz, timestamptz, text
) to authenticated;
grant execute on function public.update_trip_item(uuid, bigint, uuid, uuid, text, text)
  to authenticated;
grant execute on function public.delete_trip_item(uuid, bigint, uuid, uuid)
  to authenticated;
grant execute on function public.batch_delete_trip_items(uuid, bigint, uuid, uuid[])
  to authenticated;
grant execute on function public.complete_trip(uuid, bigint, uuid)
  to authenticated;
grant execute on function public.cancel_trip(uuid, bigint, uuid)
  to authenticated;
grant execute on function public.delete_trip(uuid, bigint, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8. 重新定义既有写入 RPC：完成态只读，并拒绝 NULL revision。
-- ---------------------------------------------------------------------------
create or replace function public.add_trip_day(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_local_date date,
  p_available_start_time time default null,
  p_available_end_time time default null,
  p_budget_limit_minor bigint default null,
  p_notes varchar(1000) default null
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  created public.trip_days%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'local_date', p_local_date,
    'available_start_time', p_available_start_time,
    'available_end_time', p_available_end_time,
    'budget_limit_minor', p_budget_limit_minor,
    'notes', p_notes
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'add_trip_day', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  insert into public.trip_days(
    trip_id,
    local_date,
    available_start_time,
    available_end_time,
    budget_limit_minor,
    notes
  ) values (
    p_trip_id,
    p_local_date,
    p_available_start_time,
    p_available_end_time,
    p_budget_limit_minor,
    p_notes
  ) returning * into created;

  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'trip_day', to_jsonb(created),
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'add_trip_day', p_idempotency_key, result
  );
  return result;
end;
$$;

create or replace function public.change_trip_timezone(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_timezone text
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := (select auth.uid());
  request_hash bytea;
  prior jsonb;
  trip_row public.trips%rowtype;
  old_timezone text;
  moved integer := 0;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_timezone is null or not exists (
    select 1 from pg_timezone_names where name = p_timezone
  ) then
    raise exception using errcode = '22023',
      message = 'timezone must be a valid IANA timezone';
  end if;

  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'timezone', p_timezone
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'change_trip_timezone', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row
  from public.trips
  where id = p_trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if p_expected_revision is null or trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;
  perform public.assert_trip_writable(p_trip_id);

  old_timezone := trip_row.timezone;
  if old_timezone = p_timezone then
    result := jsonb_build_object(
      'trip_id', p_trip_id,
      'timezone', p_timezone,
      'previous_timezone', old_timezone,
      'revision', trip_row.revision,
      'items_shifted', 0
    );
    perform public.store_itinerary_idempotency_result(
      actor, 'change_trip_timezone', p_idempotency_key, result
    );
    return result;
  end if;

  perform set_config('savorseek.timezone_migration', 'on', true);
  update public.trips set timezone = p_timezone where id = p_trip_id;
  update public.trip_items set
    planned_start_at = (planned_start_at at time zone old_timezone) at time zone p_timezone,
    planned_end_at = (planned_end_at at time zone old_timezone) at time zone p_timezone
  where trip_id = p_trip_id;
  get diagnostics moved = row_count;

  update public.trips set revision = revision + 1 where id = p_trip_id;
  result := jsonb_build_object(
    'trip_id', p_trip_id,
    'timezone', p_timezone,
    'previous_timezone', old_timezone,
    'revision', trip_row.revision + 1,
    'items_shifted', moved
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'change_trip_timezone', p_idempotency_key, result
  );
  return result;
end;
$$;

revoke all on function public.add_trip_day(
  uuid, bigint, uuid, date, time, time, bigint, varchar
) from public, anon, authenticated;
revoke all on function public.change_trip_timezone(uuid, bigint, uuid, text)
  from public, anon, authenticated;
grant execute on function public.add_trip_day(
  uuid, bigint, uuid, date, time, time, bigint, varchar
) to authenticated;
grant execute on function public.change_trip_timezone(uuid, bigint, uuid, text)
  to authenticated;
