-- 行程页面整合迁移的上库核对脚本。
--
-- 用法：在目标 Supabase 数据库中执行。每一行返回一个布尔核对结果；出现 false
-- 时不要继续客户端发布，先检查迁移是否完整应用。

select 'edit_trip_item exists' as check_name,
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'edit_trip_item'
      and pg_get_function_identity_arguments(p.oid) =
        'p_trip_id uuid, p_expected_revision bigint, p_idempotency_key uuid, p_trip_item_id uuid, p_title text, p_notes text, p_trip_day_id uuid, p_planned_start_at timestamp with time zone, p_planned_end_at timestamp with time zone, p_time_slot text'
  ) as passed;

select 'complete_trip exists' as check_name,
  to_regprocedure('public.complete_trip(uuid,bigint,uuid)') is not null as passed;

select 'cancel_trip exists' as check_name,
  to_regprocedure('public.cancel_trip(uuid,bigint,uuid)') is not null as passed;

select 'delete_trip exists' as check_name,
  to_regprocedure('public.delete_trip(uuid,bigint,uuid)') is not null as passed;

select 'assert_trip_writable exists' as check_name,
  to_regprocedure('public.assert_trip_writable(uuid)') is not null as passed;

select 'cancel_trip_item dropped' as check_name,
  to_regprocedure('public.cancel_trip_item(uuid,bigint,uuid,uuid)') is null as passed;

select 'restore_trip_item dropped' as check_name,
  to_regprocedure('public.restore_trip_item(uuid,bigint,uuid,uuid)') is null as passed;

select 'batch_cancel_trip_items dropped' as check_name,
  to_regprocedure('public.batch_cancel_trip_items(uuid,bigint,uuid,uuid[])') is null as passed;

select 'trip_items status constraint excludes cancelled' as check_name,
  exists (
    select 1
    from pg_constraint c
    join pg_class r on r.oid = c.conrelid
    join pg_namespace n on n.oid = r.relnamespace
    where n.nspname = 'public'
      and r.relname = 'trip_items'
      and c.conname = 'trip_items_status_ck'
      and pg_get_constraintdef(c.oid) =
        'CHECK ((status = ANY (ARRAY[''planned''::text, ''completed''::text, ''skipped''::text])))'
  ) as passed;

select 'active position index is unconditional' as check_name,
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'trip_items'
      and indexname = 'trip_items_active_position_uq'
      and indexdef = 'CREATE UNIQUE INDEX trip_items_active_position_uq ON public.trip_items USING btree (trip_day_id, "position")'
  ) as passed;

select 'no cancelled items remain' as check_name,
  not exists (
    select 1 from public.trip_items where status = 'cancelled'
  ) as passed;

select 'draft to completed transition present' as check_name,
  position('(old.status = ''draft'' and new.status in (''confirmed'', ''completed'', ''cancelled''))' in pg_get_functiondef('public.validate_trip_row()'::regprocedure)) > 0 as passed;

select 'completed guard uses P0003' as check_name,
  position('errcode = ''P0003''' in pg_get_functiondef('public.assert_trip_writable(uuid)'::regprocedure)) > 0 as passed;

select 'add_trip_item calls writable guard' as check_name,
  position('perform public.assert_trip_writable(p_trip_id)' in pg_get_functiondef('public.add_trip_item(uuid,bigint,uuid,uuid,text,uuid,varchar,timestamptz,timestamptz,text,integer,bigint,bigint,varchar,jsonb)'::regprocedure)) > 0 as passed;

select 'edit_trip_item calls writable guard' as check_name,
  position('perform public.assert_trip_writable(p_trip_id)' in pg_get_functiondef('public.edit_trip_item(uuid,bigint,uuid,uuid,text,text,uuid,timestamptz,timestamptz,text)'::regprocedure)) > 0 as passed;

select 'reschedule_trip_item calls writable guard' as check_name,
  position('perform public.assert_trip_writable(p_trip_id)' in pg_get_functiondef('public.reschedule_trip_item(uuid,bigint,uuid,uuid,uuid,timestamptz,timestamptz,text)'::regprocedure)) > 0 as passed;

select 'update_trip_item calls writable guard' as check_name,
  position('perform public.assert_trip_writable(p_trip_id)' in pg_get_functiondef('public.update_trip_item(uuid,bigint,uuid,uuid,text,text)'::regprocedure)) > 0 as passed;

select 'delete_trip_item calls writable guard' as check_name,
  position('perform public.assert_trip_writable(p_trip_id)' in pg_get_functiondef('public.delete_trip_item(uuid,bigint,uuid,uuid)'::regprocedure)) > 0 as passed;

select 'batch_delete_trip_items calls writable guard' as check_name,
  position('perform public.assert_trip_writable(p_trip_id)' in pg_get_functiondef('public.batch_delete_trip_items(uuid,bigint,uuid,uuid[])'::regprocedure)) > 0 as passed;
