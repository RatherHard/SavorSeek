-- 改期：调整行程项的日期、时间、时段与顺序。
--
-- 与 add_trip_item 同构（锁父行、校验所有权与 expected_revision、幂等键、
-- 只递增一次 revision），差别在于目标项必须已存在且未进入终态。
--
-- 为什么允许跨天移动：用户在 UI 上「改期」的自然预期包含换一天。跨天时项的
-- trip_day_id 与 position 都要变，而 (trip_day_id, position) 对非取消项唯一，
-- 因此新 position 由函数按目标日实际占用计算，不接受调用方传入——客户端算出的
-- 值在并发下必然过期。
--
-- 锁定标志（is_time_locked / is_order_locked）在此不阻断：数据模型文档第 22、
-- 267 行的约束是「Agent 不得修改被锁定字段」，用户本人的显式改期不在其列。
-- 库端 trigger 也只在 savorseek.actor = 'agent' 时校验这三个标志。

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
  -- 终态项不可改期：trigger 只拦状态变更，不拦时间变更，这里显式补上。
  -- 给已完成的到访改时间没有意义，且会让历史记录失真。
  if existing.status in ('completed', 'skipped', 'cancelled') then
    raise exception using errcode = '22023',
      message = 'cannot reschedule an item in a terminal state';
  end if;

  -- 目标日必须属于本行程。不校验会让项被移到别的行程日上（虽然 trigger 也会
  -- 拦，但那时报 23503，对客户端无从区分具体成因）。
  if not exists (
    select 1 from public.trip_days
    where id = p_trip_day_id and trip_id = p_trip_id
  ) then
    raise exception using errcode = '22023',
      message = 'target trip day does not belong to this trip';
  end if;

  if p_trip_day_id = existing.trip_day_id then
    -- 同日内只改时间，保持原顺序：位置未变就不该悄悄跳到末尾。
    target_position := existing.position;
  else
    -- 跨天则追加到目标日末尾。原日留下的 position 空档不回填——库端只要求
    -- 同日内唯一，不要求连续。
    select coalesce(max(position) + 1, 0) into target_position
    from public.trip_items
    where trip_day_id = p_trip_day_id and status <> 'cancelled';
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

revoke all on function public.reschedule_trip_item(
  uuid, bigint, uuid, uuid, uuid, timestamptz, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.reschedule_trip_item(
  uuid, bigint, uuid, uuid, uuid, timestamptz, timestamptz, text
) to authenticated;
