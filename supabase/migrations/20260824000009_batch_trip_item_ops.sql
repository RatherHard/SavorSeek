-- ---------------------------------------------------------------------------
-- 批量取消与批量删除行程项。
--
-- 为什么必须新增 RPC 而不能让客户端循环调用单项版本：现有每个 RPC 都会把
-- trips.revision 自增一次，循环到第二次时客户端手里的 expected_revision 已过期，
-- 必然收到 P0002。中间重新读一次 revision 也不行——那等于放弃乐观并发控制
-- （两次读之间的他方写入会被静默覆盖）。
--
-- 因此这两个函数在单个事务内处理整批，并且只把父行程的修订号递增一次，与
-- 「受控事务必须只递增一次父行程修订号」的既有约定一致（行程表数据模型 第 326
-- 行）。validate_trip_row 亦强制 revision 只能不变或 +1，循环递增会直接被拒。
--
-- 语义选择：整批原子。任一项不合法（不存在、状态不允许）即整批回滚，不做
-- 「跳过失败项继续」——部分成功后用户无法从界面上分辨哪几项生效了，而重试
-- 又会因状态已变而再次失败。
-- ---------------------------------------------------------------------------

-- 批量取消：软删除，记录与 place_snapshot 保留，可经 restore_trip_item 恢复。
create or replace function public.batch_cancel_trip_items(
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
  affected_ids uuid[];
  result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  if p_trip_item_ids is null or cardinality(p_trip_item_ids) = 0 then
    raise exception using errcode = '22023',
      message = 'at least one trip item id is required';
  end if;

  -- 去重后再计数：同一个 id 传两次不该被当成「有一项不存在」。
  select array_agg(distinct id) into distinct_ids
  from unnest(p_trip_item_ids) as id;

  -- 请求哈希须对顺序不敏感：同一批 id 换个顺序是同一个请求，否则重试时顺序
  -- 稍变就会被判为「键复用但请求不同」而报 22023。
  request_hash := digest(jsonb_build_object(
    'trip_id', p_trip_id,
    'trip_item_ids', (
      select jsonb_agg(id order by id) from unnest(distinct_ids) as id
    )
  )::text, 'sha256');
  prior := public.itinerary_idempotency_result(
    actor, 'batch_cancel_trip_items', p_idempotency_key, request_hash
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

  -- 全部 id 必须属于本行程：跨行程的 id 与不存在的 id 一样按 42501 处理，
  -- 两者对调用者都应表现为「查不到」，不泄漏他人行程中是否存在该 id。
  select count(*) into found_count from public.trip_items
  where trip_id = p_trip_id and id = any(distinct_ids);
  if found_count <> cardinality(distinct_ids) then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;

  select count(*) into blocked_count from public.trip_items
  where trip_id = p_trip_id and id = any(distinct_ids) and status <> 'planned';
  if blocked_count > 0 then
    raise exception using errcode = '22023',
      message = 'only planned items can be cancelled';
  end if;

  with updated as (
    update public.trip_items set status = 'cancelled'
    where trip_id = p_trip_id and id = any(distinct_ids)
    returning id
  )
  select array_agg(id order by id) into affected_ids from updated;

  -- 只递增一次，无论批量涉及多少项。
  update public.trips set revision = revision + 1 where id = p_trip_id;

  result := jsonb_build_object(
    'cancelled_trip_item_ids', to_jsonb(affected_ids),
    'cancelled_count', coalesce(cardinality(affected_ids), 0),
    'revision', trip_row.revision + 1
  );
  perform public.store_itinerary_idempotency_result(
    actor, 'batch_cancel_trip_items', p_idempotency_key, result
  );
  return result;
end;
$$;

-- 批量删除：硬删除，不可恢复。调用方须先向用户确认。
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

  select * into trip_row from public.trips
  where id = p_trip_id and user_id = actor for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  select count(*) into found_count from public.trip_items
  where trip_id = p_trip_id and id = any(distinct_ids);
  if found_count <> cardinality(distinct_ids) then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;

  -- 与单项版本一致：已完成/已跳过的项是历史事实，不允许删除。
  select count(*) into blocked_count from public.trip_items
  where trip_id = p_trip_id and id = any(distinct_ids)
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

-- 与既有八个客户端可调 RPC 相同的授权姿态：先全撤，再只授 authenticated。
revoke all on function public.batch_cancel_trip_items(uuid, bigint, uuid, uuid[])
  from public, anon, authenticated;
revoke all on function public.batch_delete_trip_items(uuid, bigint, uuid, uuid[])
  from public, anon, authenticated;

grant execute on function public.batch_cancel_trip_items(uuid, bigint, uuid, uuid[])
  to authenticated;
grant execute on function public.batch_delete_trip_items(uuid, bigint, uuid, uuid[])
  to authenticated;
