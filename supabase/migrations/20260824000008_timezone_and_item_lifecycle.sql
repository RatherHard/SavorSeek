-- 行程时区更改，以及行程项的取消 / 恢复 / 删除。
--
-- 这几件事放在同一个迁移里，因为它们都要求放宽既有 trigger 的约束，而放宽的
-- 理由必须与被放宽的代码成对记录，否则后来者会以为约束是被误删的。
--
-- 下面两个 validate_* 函数的函数体从 20260821000002_itinerary_schema.sql 原样
-- 复制，各只改动一处，改动点在原位注明。

-- ---------------------------------------------------------------------------
-- 放宽一：允许经受控事务更改行程时区
-- ---------------------------------------------------------------------------
-- 原实现在存在 trip_days 时一律拒绝更改 timezone。该约束的本意（数据模型文档
-- 第 268 行）是「不得直接修改，如需变更必须通过专用迁移事务重新校验每个行程项的
-- 本地日期归属」——禁止的是裸 UPDATE，而非这一能力本身。
--
-- 故改为：仅当会话标志 savorseek.timezone_migration = 'on' 时放行。该标志只由
-- 下方的 change_trip_timezone 以 set_config(..., true) 设置，事务结束即失效；
-- 客户端无法自行设置（PostgREST 不暴露 set_config）。
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
    -- 唯一改动：受控迁移事务内放行时区更改。
    if child_exists and new.timezone is distinct from old.timezone
      and coalesce(current_setting('savorseek.timezone_migration', true), '') <> 'on' then
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

-- ---------------------------------------------------------------------------
-- 放宽二：允许把已取消的行程项恢复为 planned
-- ---------------------------------------------------------------------------
-- 原实现把 completed / skipped / cancelled 一律视为不可再变更的终态。但 cancelled
-- 与前两者性质不同：completed / skipped 是「已经发生过的事实」，改动即篡改历史；
-- cancelled 只是「用户当前不打算去」，是一个可以反悔的意图。
--
-- 产品决策（用户 2026-08-24）：取消后的项在 UI 上仍可见且可恢复。故仅放开
-- cancelled -> planned 一条转换，completed / skipped 仍然冻结。
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
    -- 唯一改动：把 cancelled 从「不可变更的终态」中摘出，允许恢复为 planned。
    if old.status in ('completed', 'skipped') and new.status is distinct from old.status then
      raise exception using errcode = '22023', message = 'terminal item status cannot change';
    end if;
    if old.status = 'cancelled' and new.status is distinct from old.status
      and new.status <> 'planned' then
      raise exception using errcode = '22023',
        message = 'a cancelled item may only be restored to planned';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 更改行程时区
-- ---------------------------------------------------------------------------
-- 语义（用户 2026-08-24 决策）：保留当地钟点。原本安排在「19:00」的项，改到东京
-- 时区后仍是「东京 19:00」，库内 UTC 时刻随之重算。
--
-- 这也是唯一能让项继续归属原 trip_day 的做法：trip_days.local_date 是行程时区下
-- 的日期，保留钟点即保留当地日期，归属关系天然成立。若改为保留绝对时刻，折算出的
-- 当地日期可能跳到相邻一天，与 local_date 不符而被 trigger 拒绝。
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
    raise exception using errcode = '22023', message = 'timezone must be a valid IANA timezone';
  end if;

  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id, 'timezone', p_timezone
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'change_trip_timezone', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row from public.trips
  where id = p_trip_id and user_id = actor for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  old_timezone := trip_row.timezone;
  if old_timezone = p_timezone then
    -- 无变化时不写入也不递增 revision：让重复提交成为无害操作。
    result := jsonb_build_object(
      'trip_id', p_trip_id, 'timezone', p_timezone,
      'previous_timezone', old_timezone,
      'revision', trip_row.revision, 'items_shifted', 0
    );
    perform public.store_itinerary_idempotency_result(
      actor, 'change_trip_timezone', p_idempotency_key, result
    );
    return result;
  end if;

  -- 声明这是受控迁移事务，放行 validate_trip_row 的时区约束。
  -- 第三个参数为 true：仅在本事务内有效，提交或回滚后自动失效。
  perform set_config('savorseek.timezone_migration', 'on', true);

  update public.trips set timezone = p_timezone where id = p_trip_id;

  -- 保留当地钟点：按旧时区取出墙上时间，再按新时区重新解释。
  -- 必须在 trips.timezone 更新之后执行——item 的 trigger 按父行程的当前时区校验
  -- 日期归属，此时新时刻与新时区一致，校验才能通过。
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

-- ---------------------------------------------------------------------------
-- 取消 / 恢复 / 删除行程项
-- ---------------------------------------------------------------------------
-- 取消是软删除：记录与 place_snapshot 保留，历史到访项因此仍可读（数据模型文档
-- 第 249 行）。(trip_day_id, position) 的唯一索引本就排除 cancelled，故取消后
-- 不占位。
create or replace function public.cancel_trip_item(
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
  updated public.trip_items%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id, 'trip_item_id', p_trip_item_id
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'cancel_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row from public.trips
  where id = p_trip_id and user_id = actor for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  select * into existing from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  if existing.status <> 'planned' then
    raise exception using errcode = '22023',
      message = 'only a planned item can be cancelled';
  end if;

  update public.trip_items set status = 'cancelled'
  where id = p_trip_item_id returning * into updated;
  update public.trips set revision = revision + 1 where id = p_trip_id;

  result := jsonb_build_object(
    'trip_item', to_jsonb(updated), 'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'cancel_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

-- 恢复：把已取消的项放回 planned。
--
-- position 需要判断而非直接沿用：唯一索引排除 cancelled，取消期间同一天可能已
-- 排入新项占用了原位置，沿用旧值会撞 23505。
create or replace function public.restore_trip_item(
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
  target_position integer;
  updated public.trip_items%rowtype;
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id, 'trip_item_id', p_trip_item_id
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'restore_trip_item', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  select * into trip_row from public.trips
  where id = p_trip_id and user_id = actor for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  select * into existing from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  if existing.status <> 'cancelled' then
    raise exception using errcode = '22023',
      message = 'only a cancelled item can be restored';
  end if;

  -- 原位置仍空着就沿用，保持用户记忆中的顺序；被占了才追加到末尾。
  if exists (
    select 1 from public.trip_items
    where trip_day_id = existing.trip_day_id
      and position = existing.position
      and status <> 'cancelled'
      and id <> p_trip_item_id
  ) then
    select coalesce(max(position) + 1, 0) into target_position
    from public.trip_items
    where trip_day_id = existing.trip_day_id and status <> 'cancelled';
  else
    target_position := existing.position;
  end if;

  update public.trip_items
  set status = 'planned', position = target_position
  where id = p_trip_item_id returning * into updated;
  update public.trips set revision = revision + 1 where id = p_trip_id;

  result := jsonb_build_object(
    'trip_item', to_jsonb(updated), 'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'restore_trip_item', p_idempotency_key, result
  );
  return result;
end;
$$;

-- 硬删除：从表中彻底移除。
--
-- 与取消并存（用户 2026-08-24 决策）：取消表达「暂时不去，之后可能改主意」，
-- 硬删除表达「加错了，本不该存在」。后者不可恢复，客户端须二次确认。
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

  select * into trip_row from public.trips
  where id = p_trip_id and user_id = actor for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  select * into existing from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;
  -- 已完成 / 已跳过的项是历史事实，不允许抹除。
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

revoke all on function public.validate_trip_row() from public, anon, authenticated;
revoke all on function public.validate_trip_item_row() from public, anon, authenticated;
revoke all on function public.change_trip_timezone(uuid, bigint, uuid, text) from public, anon, authenticated;
revoke all on function public.cancel_trip_item(uuid, bigint, uuid, uuid) from public, anon, authenticated;
revoke all on function public.restore_trip_item(uuid, bigint, uuid, uuid) from public, anon, authenticated;
revoke all on function public.delete_trip_item(uuid, bigint, uuid, uuid) from public, anon, authenticated;
grant execute on function public.change_trip_timezone(uuid, bigint, uuid, text) to authenticated;
grant execute on function public.cancel_trip_item(uuid, bigint, uuid, uuid) to authenticated;
grant execute on function public.restore_trip_item(uuid, bigint, uuid, uuid) to authenticated;
grant execute on function public.delete_trip_item(uuid, bigint, uuid, uuid) to authenticated;
