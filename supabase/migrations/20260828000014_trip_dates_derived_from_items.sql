-- 节点日期驱动的行程日历。
-- 节点日期是唯一事实来源；日期写入在 *_on_date RPC 中原子完成。

alter table public.trips alter column start_date drop not null;
alter table public.trips alter column end_date drop not null;
alter table public.trips drop constraint if exists trips_date_range_ck;
alter table public.trips add constraint trips_date_range_ck check (
  (start_date is null and end_date is null)
  or (start_date is not null and end_date is not null and end_date >= start_date)
);

create or replace function public.validate_trip_day_row()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare parent public.trips%rowtype;
begin
  new.notes := nullif(btrim(new.notes), '');
  select * into parent from public.trips where id = new.trip_id;
  if not found then raise exception using errcode = '23503', message = 'trip does not exist'; end if;
  if parent.start_date is not null and (new.local_date < parent.start_date or new.local_date > parent.end_date) then
    raise exception using errcode = '23514', message = 'trip day is outside the trip date range';
  end if;
  return new;
end;
$$;

create or replace function public.validate_trip_row()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare money_exists boolean;
begin
  new.title := btrim(new.title);
  if char_length(new.title) < 1 then raise exception using errcode = '22023', message = 'trip title must not be blank'; end if;
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then raise exception using errcode = '22023', message = 'timezone must be a valid IANA timezone'; end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.user_id is distinct from old.user_id then raise exception using errcode = '42501', message = 'trip identity cannot be changed'; end if;
    if new.revision not in (old.revision, old.revision + 1) then raise exception using errcode = '22023', message = 'revision may only stay unchanged or increase by one'; end if;
    if new.status is distinct from old.status and not ((old.status = 'draft' and new.status in ('confirmed','in_progress','completed','cancelled')) or (old.status = 'confirmed' and new.status in ('in_progress','completed','cancelled')) or (old.status = 'in_progress' and new.status in ('completed','cancelled'))) then raise exception using errcode = '22023', message = 'invalid trip status transition'; end if;
    if new.timezone is distinct from old.timezone then raise exception using errcode = '23514', message = 'timezone cannot change after trip creation'; end if;
    select exists (select 1 from public.trip_days where trip_id = old.id and budget_limit_minor is not null union all select 1 from public.trip_items where trip_id = old.id and (estimated_cost_min_minor is not null or estimated_cost_max_minor is not null)) into money_exists;
    if money_exists and new.currency_code is distinct from old.currency_code then raise exception using errcode = '23514', message = 'currency cannot change while aggregate amounts exist'; end if;
  end if;
  return new;
end;
$$;

create or replace function public.sync_trip_calendar(p_trip_id uuid)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare parent public.trips%rowtype; min_date date; max_date date;
begin
  select * into parent from public.trips where id = p_trip_id for update;
  if not found then raise exception using errcode = '42501', message = 'trip not found'; end if;
  select min((planned_start_at at time zone parent.timezone)::date), max((planned_start_at at time zone parent.timezone)::date) into min_date,max_date from public.trip_items where trip_id=p_trip_id;
  if min_date is null then delete from public.trip_days where trip_id=p_trip_id; update public.trips set start_date=null,end_date=null where id=p_trip_id; return; end if;
  update public.trips set start_date=min_date,end_date=max_date where id=p_trip_id;
  insert into public.trip_days(trip_id,local_date) select p_trip_id,value::date from generate_series(min_date,max_date,interval '1 day') as series(value) on conflict(trip_id,local_date) do nothing;
  delete from public.trip_days d where d.trip_id=p_trip_id and (d.local_date<min_date or d.local_date>max_date) and not exists(select 1 from public.trip_items i where i.trip_day_id=d.id);
end;
$$;
revoke all on function public.sync_trip_calendar(uuid) from public,anon,authenticated;

create or replace function public.trip_date_allowed(p_timezone text,p_local_date date)
returns boolean language sql stable set search_path=public,pg_temp as $$
select p_local_date between (((clock_timestamp() at time zone p_timezone)::date - interval '10 years')::date) and (((clock_timestamp() at time zone p_timezone)::date + interval '10 years')::date)
$$;
revoke all on function public.trip_date_allowed(text,date) from public,anon,authenticated;

-- 创建允许空日期；日期在首个节点写入时产生。
create or replace function public.create_trip(p_idempotency_key uuid,p_title varchar(80),p_timezone text default 'Asia/Shanghai',p_start_date date default null,p_end_date date default null,p_party_size smallint default 1,p_currency_code char(3) default 'CNY',p_budget_limit_minor bigint default null,p_budget_scope text default null,p_default_travel_mode text default 'walking')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare actor uuid:=auth.uid(); created public.trips%rowtype; result jsonb; request_hash bytea; prior jsonb;
begin
  if actor is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_start_date is not null or p_end_date is not null then raise exception using errcode='22023',message='new trips must not specify dates'; end if;
  request_hash:=digest(jsonb_build_object('title',p_title,'timezone',p_timezone,'party_size',p_party_size,'currency_code',p_currency_code,'budget_limit_minor',p_budget_limit_minor,'budget_scope',p_budget_scope,'default_travel_mode',p_default_travel_mode)::text,'sha256');
  prior:=public.itinerary_idempotency_result(actor,'create_trip',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  insert into public.trips(user_id,title,timezone,start_date,end_date,party_size,currency_code,budget_limit_minor,budget_scope,default_travel_mode) values(actor,p_title,p_timezone,null,null,p_party_size,p_currency_code,p_budget_limit_minor,p_budget_scope,p_default_travel_mode) returning * into created;
  result:=to_jsonb(created); perform public.store_itinerary_idempotency_result(actor,'create_trip',p_idempotency_key,result); return result;
end; $$;

create or replace function public.add_trip_item_on_date(p_trip_id uuid,p_expected_revision bigint,p_idempotency_key uuid,p_local_date date,p_item_type text,p_place_id uuid,p_title varchar(120),p_planned_start_at timestamptz,p_planned_end_at timestamptz,p_time_slot text default 'flexible',p_position integer default 0,p_estimated_cost_min_minor bigint default null,p_estimated_cost_max_minor bigint default null,p_notes varchar(1000) default null,p_place_snapshot jsonb default null)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare actor uuid:=auth.uid(); parent public.trips%rowtype; target public.trip_days%rowtype; created public.trip_items%rowtype; result jsonb; prior jsonb; request_hash bytea;
begin
  if actor is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_expected_revision is null or p_idempotency_key is null then raise exception using errcode='22023',message='revision and idempotency key are required'; end if;
  request_hash:=digest(jsonb_build_object('trip_id',p_trip_id,'local_date',p_local_date,'item_type',p_item_type,'place_id',p_place_id,'title',p_title,'planned_start_at',p_planned_start_at,'planned_end_at',p_planned_end_at,'time_slot',p_time_slot,'position',p_position,'estimated_cost_min_minor',p_estimated_cost_min_minor,'estimated_cost_max_minor',p_estimated_cost_max_minor,'notes',p_notes,'place_snapshot',p_place_snapshot)::text,'sha256');
  prior:=public.itinerary_idempotency_result(actor,'add_trip_item_on_date',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into parent from public.trips where id=p_trip_id and user_id=actor for update; if not found then raise exception using errcode='42501',message='trip not found'; end if;
  if parent.revision<>p_expected_revision then raise exception using errcode='P0002',message='trip revision conflict'; end if; perform public.assert_trip_writable(p_trip_id);
  if p_local_date is null or not public.trip_date_allowed(parent.timezone,p_local_date) then raise exception using errcode='22023',message='trip item date is outside the supported range'; end if;
  if (p_planned_start_at at time zone parent.timezone)::date<>p_local_date then raise exception using errcode='23514',message='trip item date does not match start time'; end if;
  update public.trips set start_date=least(coalesce(start_date,p_local_date),p_local_date),end_date=greatest(coalesce(end_date,p_local_date),p_local_date) where id=p_trip_id;
  insert into public.trip_days(trip_id,local_date) values(p_trip_id,p_local_date) on conflict(trip_id,local_date) do nothing;
  select * into target from public.trip_days where trip_id=p_trip_id and local_date=p_local_date;
  select coalesce(max(position)+1,0) into p_position from public.trip_items where trip_day_id=target.id;
  insert into public.trip_items(trip_id,trip_day_id,item_type,place_id,title,planned_start_at,planned_end_at,time_slot,position,estimated_cost_min_minor,estimated_cost_max_minor,notes,place_snapshot) values(p_trip_id,target.id,p_item_type,p_place_id,p_title,p_planned_start_at,p_planned_end_at,p_time_slot,p_position,p_estimated_cost_min_minor,p_estimated_cost_max_minor,p_notes,p_place_snapshot) returning * into created;
  perform public.sync_trip_calendar(p_trip_id); update public.trips set revision=revision+1 where id=p_trip_id;
  result:=jsonb_build_object('trip_item',to_jsonb(created),'revision',parent.revision+1); perform public.store_itinerary_idempotency_result(actor,'add_trip_item_on_date',p_idempotency_key,result); return result;
end; $$;

create or replace function public.edit_trip_item_on_date(p_trip_id uuid,p_expected_revision bigint,p_idempotency_key uuid,p_trip_item_id uuid,p_title text,p_notes text,p_local_date date,p_planned_start_at timestamptz,p_planned_end_at timestamptz,p_time_slot text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare actor uuid:=auth.uid(); parent public.trips%rowtype; old_item public.trip_items%rowtype; target public.trip_days%rowtype; updated public.trip_items%rowtype; pos integer; result jsonb; request_hash bytea; prior jsonb;
begin
  if actor is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_expected_revision is null or p_idempotency_key is null then raise exception using errcode='22023',message='revision and idempotency key are required'; end if;
  request_hash:=digest(jsonb_build_object('trip_id',p_trip_id,'trip_item_id',p_trip_item_id,'title',p_title,'notes',p_notes,'local_date',p_local_date,'planned_start_at',p_planned_start_at,'planned_end_at',p_planned_end_at,'time_slot',p_time_slot)::text,'sha256'); prior:=public.itinerary_idempotency_result(actor,'edit_trip_item_on_date',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into parent from public.trips where id=p_trip_id and user_id=actor for update; if not found then raise exception using errcode='42501',message='trip not found'; end if;
  if parent.revision<>p_expected_revision then raise exception using errcode='P0002',message='trip revision conflict'; end if; perform public.assert_trip_writable(p_trip_id);
  select * into old_item from public.trip_items where id=p_trip_item_id and trip_id=p_trip_id; if not found then raise exception using errcode='42501',message='trip item not found'; end if;
  if old_item.status in ('completed','skipped') then raise exception using errcode='22023',message='a completed or skipped item cannot be edited'; end if;
  if p_local_date is null or not public.trip_date_allowed(parent.timezone,p_local_date) then raise exception using errcode='22023',message='trip item date is outside the supported range'; end if;
  if (p_planned_start_at at time zone parent.timezone)::date<>p_local_date then raise exception using errcode='23514',message='trip item date does not match start time'; end if;
  update public.trips set start_date=least(coalesce(start_date,p_local_date),p_local_date),end_date=greatest(coalesce(end_date,p_local_date),p_local_date) where id=p_trip_id;
  insert into public.trip_days(trip_id,local_date) values(p_trip_id,p_local_date) on conflict(trip_id,local_date) do nothing;
  select * into target from public.trip_days where trip_id=p_trip_id and local_date=p_local_date;
  if target.id=old_item.trip_day_id then pos:=old_item.position; else select coalesce(max(position)+1,0) into pos from public.trip_items where trip_day_id=target.id; end if;
  update public.trip_items set title=btrim(p_title),notes=nullif(btrim(coalesce(p_notes,'')),''),trip_day_id=target.id,planned_start_at=p_planned_start_at,planned_end_at=p_planned_end_at,time_slot=p_time_slot,position=pos where id=p_trip_item_id returning * into updated;
  perform public.sync_trip_calendar(p_trip_id); update public.trips set revision=revision+1 where id=p_trip_id;
  result:=jsonb_build_object('trip_item',to_jsonb(updated),'revision',parent.revision+1); perform public.store_itinerary_idempotency_result(actor,'edit_trip_item_on_date',p_idempotency_key,result); return result;
end; $$;

create or replace function public.reschedule_trip_item_on_date(p_trip_id uuid,p_expected_revision bigint,p_idempotency_key uuid,p_trip_item_id uuid,p_local_date date,p_planned_start_at timestamptz,p_planned_end_at timestamptz,p_time_slot text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare actor uuid:=auth.uid(); parent public.trips%rowtype; old_item public.trip_items%rowtype; target public.trip_days%rowtype; updated public.trip_items%rowtype; pos integer; result jsonb; request_hash bytea; prior jsonb;
begin
  if actor is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_expected_revision is null or p_idempotency_key is null then raise exception using errcode='22023',message='revision and idempotency key are required'; end if;
  request_hash:=digest(jsonb_build_object('trip_id',p_trip_id,'trip_item_id',p_trip_item_id,'local_date',p_local_date,'planned_start_at',p_planned_start_at,'planned_end_at',p_planned_end_at,'time_slot',p_time_slot)::text,'sha256'); prior:=public.itinerary_idempotency_result(actor,'reschedule_trip_item_on_date',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into parent from public.trips where id=p_trip_id and user_id=actor for update; if not found then raise exception using errcode='42501',message='trip not found'; end if;
  if parent.revision<>p_expected_revision then raise exception using errcode='P0002',message='trip revision conflict'; end if; perform public.assert_trip_writable(p_trip_id);
  select * into old_item from public.trip_items where id=p_trip_item_id and trip_id=p_trip_id; if not found then raise exception using errcode='42501',message='trip item not found'; end if;
  if old_item.status in ('completed','skipped') then raise exception using errcode='22023',message='a completed or skipped item cannot be rescheduled'; end if;
  if p_local_date is null or not public.trip_date_allowed(parent.timezone,p_local_date) then raise exception using errcode='22023',message='trip item date is outside the supported range'; end if;
  if (p_planned_start_at at time zone parent.timezone)::date<>p_local_date then raise exception using errcode='23514',message='trip item date does not match start time'; end if;
  update public.trips set start_date=least(coalesce(start_date,p_local_date),p_local_date),end_date=greatest(coalesce(end_date,p_local_date),p_local_date) where id=p_trip_id;
  insert into public.trip_days(trip_id,local_date) values(p_trip_id,p_local_date) on conflict(trip_id,local_date) do nothing;
  select * into target from public.trip_days where trip_id=p_trip_id and local_date=p_local_date;
  if target.id=old_item.trip_day_id then pos:=old_item.position; else select coalesce(max(position)+1,0) into pos from public.trip_items where trip_day_id=target.id; end if;
  update public.trip_items set trip_day_id=target.id,planned_start_at=p_planned_start_at,planned_end_at=p_planned_end_at,time_slot=p_time_slot,position=pos where id=p_trip_item_id returning * into updated;
  perform public.sync_trip_calendar(p_trip_id); update public.trips set revision=revision+1 where id=p_trip_id;
  result:=jsonb_build_object('trip_item',to_jsonb(updated),'revision',parent.revision+1); perform public.store_itinerary_idempotency_result(actor,'reschedule_trip_item_on_date',p_idempotency_key,result); return result;
end; $$;

-- Legacy delete paths also trigger calendar synchronization; this keeps the invariant while old clients roll forward.
create or replace function public.sync_trip_calendar_after_item()
returns trigger language plpgsql security definer set search_path=public,extensions,pg_temp as $$
begin perform public.sync_trip_calendar(coalesce(new.trip_id,old.trip_id)); return coalesce(new,old); end;
$$;
revoke all on function public.sync_trip_calendar_after_item() from public,anon,authenticated;
drop trigger if exists sync_trip_calendar_after_item on public.trip_items;
create constraint trigger sync_trip_calendar_after_item after insert or update or delete on public.trip_items deferrable initially deferred for each row execute function public.sync_trip_calendar_after_item();

revoke all on function public.add_trip_item_on_date(uuid,bigint,uuid,date,text,uuid,varchar,timestamptz,timestamptz,text,integer,bigint,bigint,varchar,jsonb) from public,anon,authenticated;
revoke all on function public.edit_trip_item_on_date(uuid,bigint,uuid,uuid,text,text,date,timestamptz,timestamptz,text) from public,anon,authenticated;
revoke all on function public.reschedule_trip_item_on_date(uuid,bigint,uuid,uuid,date,timestamptz,timestamptz,text) from public,anon,authenticated;
grant execute on function public.add_trip_item_on_date(uuid,bigint,uuid,date,text,uuid,varchar,timestamptz,timestamptz,text,integer,bigint,bigint,varchar,jsonb) to authenticated;
grant execute on function public.edit_trip_item_on_date(uuid,bigint,uuid,uuid,text,text,date,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.reschedule_trip_item_on_date(uuid,bigint,uuid,uuid,date,timestamptz,timestamptz,text) to authenticated;

-- Existing rows are reconciled from their node dates and missing interior days are filled.
do $$ declare r record; d date; lo date; hi date; begin
  for r in select id,timezone from public.trips loop
    select min((i.planned_start_at at time zone r.timezone)::date),max((i.planned_start_at at time zone r.timezone)::date) into lo,hi from public.trip_items i where i.trip_id=r.id;
    if lo is null then delete from public.trip_days where trip_id=r.id; update public.trips set start_date=null,end_date=null where id=r.id;
    else update public.trips set start_date=lo,end_date=hi where id=r.id; d:=lo; while d<=hi loop insert into public.trip_days(trip_id,local_date) values(r.id,d) on conflict(trip_id,local_date) do nothing; d:=d+1; end loop; end if;
  end loop;
end $$;
