-- 修正 revision 冲突的错误码。
--
-- 原实现用 SQLSTATE 40001（serialization_failure）表达乐观并发冲突。该码在
-- PostgREST 中被归类为可重试的瞬时失败，客户端一旦传入过期 revision，
-- PostgREST 会反复重试同一语句；而这里的冲突是确定性的，重试永远不会成功，
-- 最终由网关在 60 秒后返回 504。实测（2026-08-23）：正确 revision 的写入
-- 正常返回，仅冲突路径挂起至 504，读路径不受影响。
--
-- 改用 P0002：PostgREST 不会重试，直接把消息透传给客户端。客户端据此映射为
-- conflict 分支并提示重新加载（见 trip_repository.dart 的 translatePostgrestError）。
--
-- 除 errcode 外函数体与签名保持不变，上一迁移的 grant execute 因此继续有效。

create or replace function public.add_trip_day(
  p_trip_id uuid, p_expected_revision bigint, p_idempotency_key uuid, p_local_date date,
  p_available_start_time time default null, p_available_end_time time default null,
  p_budget_limit_minor bigint default null, p_notes varchar(1000) default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare actor uuid := (select auth.uid()); request_hash bytea; prior jsonb; trip_row public.trips%rowtype; created public.trip_days%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  request_hash := digest(jsonb_build_object('trip_id',p_trip_id,'local_date',p_local_date,'available_start_time',p_available_start_time,'available_end_time',p_available_end_time,'budget_limit_minor',p_budget_limit_minor,'notes',p_notes)::text,'sha256');
  prior := public.itinerary_idempotency_result(actor,'add_trip_day',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into trip_row from public.trips where id=p_trip_id and user_id=actor for update;
  if not found then raise exception using errcode = '42501', message = 'trip not found'; end if;
  if trip_row.revision <> p_expected_revision then raise exception using errcode = 'P0002', message = 'trip revision conflict'; end if;
  insert into public.trip_days(trip_id,local_date,available_start_time,available_end_time,budget_limit_minor,notes)
  values(p_trip_id,p_local_date,p_available_start_time,p_available_end_time,p_budget_limit_minor,p_notes) returning * into created;
  update public.trips set revision=revision+1 where id=p_trip_id;
  result := jsonb_build_object('trip_day',to_jsonb(created),'revision',trip_row.revision+1); perform public.store_itinerary_idempotency_result(actor,'add_trip_day',p_idempotency_key,result); return result;
end;
$$;

create or replace function public.add_trip_item(
  p_trip_id uuid, p_expected_revision bigint, p_idempotency_key uuid, p_trip_day_id uuid,
  p_item_type text, p_place_id uuid, p_title varchar(120), p_planned_start_at timestamptz,
  p_planned_end_at timestamptz, p_time_slot text default 'flexible', p_position integer default 0,
  p_estimated_cost_min_minor bigint default null, p_estimated_cost_max_minor bigint default null,
  p_notes varchar(1000) default null, p_place_snapshot jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare actor uuid := (select auth.uid()); request_hash bytea; prior jsonb; trip_row public.trips%rowtype; created public.trip_items%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  request_hash := digest(jsonb_build_object('trip_id',p_trip_id,'trip_day_id',p_trip_day_id,'item_type',p_item_type,'place_id',p_place_id,'title',p_title,'planned_start_at',p_planned_start_at,'planned_end_at',p_planned_end_at,'time_slot',p_time_slot,'position',p_position,'estimated_cost_min_minor',p_estimated_cost_min_minor,'estimated_cost_max_minor',p_estimated_cost_max_minor,'notes',p_notes,'place_snapshot',p_place_snapshot)::text,'sha256');
  prior := public.itinerary_idempotency_result(actor,'add_trip_item',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into trip_row from public.trips where id=p_trip_id and user_id=actor for update;
  if not found then raise exception using errcode = '42501', message = 'trip not found'; end if;
  if trip_row.revision <> p_expected_revision then raise exception using errcode = 'P0002', message = 'trip revision conflict'; end if;
  insert into public.trip_items(trip_id,trip_day_id,item_type,place_id,title,planned_start_at,planned_end_at,time_slot,position,estimated_cost_min_minor,estimated_cost_max_minor,notes,place_snapshot)
  values(p_trip_id,p_trip_day_id,p_item_type,p_place_id,p_title,p_planned_start_at,p_planned_end_at,p_time_slot,p_position,p_estimated_cost_min_minor,p_estimated_cost_max_minor,p_notes,p_place_snapshot) returning * into created;
  update public.trips set revision=revision+1 where id=p_trip_id;
  result := jsonb_build_object('trip_item',to_jsonb(created),'revision',trip_row.revision+1); perform public.store_itinerary_idempotency_result(actor,'add_trip_item',p_idempotency_key,result); return result;
end;
$$;
