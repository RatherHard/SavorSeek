-- ---------------------------------------------------------------------------
-- 修改行程项的标题与备注。
--
-- 为什么单独一个 RPC 而不扩展 reschedule_trip_item：一个 RPC 只负责一组字段，
-- 错误语义才好定义。时间归 reschedule_trip_item，状态归 cancel / restore /
-- delete，内容归本函数。混在一起后「22023」会同时意味着时间不合法、状态不允许
-- 与标题为空三件事，客户端无从分辨。
--
-- 语义决定（设计文档 2026-08-24 行程页面两级化重构）：
--
-- 1. 只改 title 与 notes，不碰其他字段。
--
-- 2. 两个参数都必填，不支持「传 null 表示不改」。notes 的「清空」与「不改」都会
--    想用 null 表达，二义性只能靠额外哨兵值解决。UI 侧本就是从预填当前值的表单
--    提交，两个字段总是一起送；清空备注即传空串。
--
-- 3. 已取消的项允许编辑：它还可能被恢复，在恢复前顺手改备注是合理的。已完成与
--    已跳过的项不可编辑——它们是历史事实，改标题会让记录与当时发生的事不符。
--
-- 无需修改 schema：title 为 varchar(120)、notes 为 varchar(1000)，两者都不在
-- is_place_locked / is_time_locked / is_order_locked 的涵盖范围内；
-- validate_trip_item_row 的 UPDATE 分支只拦终态项的 status 变更，本 RPC 不动
-- status，故通过。
-- ---------------------------------------------------------------------------
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

  -- 在此归一而非依赖触发器：下面的显式长度校验必须是对最终值做的，否则
  -- 「120 个字符加两个空格」会先通过校验、再被触发器 btrim 成合法值，校验就白做
  -- 了。触发器仍会再做一次，两处结果一致，不冲突。
  clean_title := btrim(coalesce(p_title, ''));
  clean_notes := nullif(btrim(coalesce(p_notes, '')), '');

  -- 提前显式检查，不依赖表约束报 23514：客户端的错误码映射按 22023 处理
  -- 「请求内容不合法」，23514 会落到兜底分支显示原始英文约束名。
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

  -- 哈希覆盖 trip_item_id + title + notes：同一把键配不同内容须报 22023
  -- （由 itinerary_idempotency_result 内部比对后抛出），与既有 RPC 一致。
  -- 用归一后的值：多打一个尾空格不该被判为「不同的请求」。
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

  select * into trip_row from public.trips
  where id = p_trip_id and user_id = actor for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = 'P0002', message = 'trip revision conflict';
  end if;

  -- 跨行程的 id 与不存在的 id 同按 42501 处理：两者对调用者都应表现为
  -- 「查不到」，不泄漏他人行程中是否存在该 id。
  select * into existing from public.trip_items
  where id = p_trip_item_id and trip_id = p_trip_id;
  if not found then
    raise exception using errcode = '42501', message = 'trip item not found';
  end if;

  -- cancelled 不在此列：已取消的项仍可编辑（见文件头语义决定第 3 条）。
  if existing.status in ('completed', 'skipped') then
    raise exception using errcode = '22023',
      message = 'a completed or skipped item cannot be edited';
  end if;

  update public.trip_items
  set title = clean_title, notes = clean_notes
  where id = p_trip_item_id returning * into updated;

  -- 只递增一次。
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

-- 与既有客户端可调 RPC 相同的授权姿态：先全撤，再只授 authenticated。
revoke all on function public.update_trip_item(uuid, bigint, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.update_trip_item(uuid, bigint, uuid, uuid, text, text)
  to authenticated;
