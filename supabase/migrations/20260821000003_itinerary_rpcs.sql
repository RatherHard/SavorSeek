-- Itinerary RPCs. These are deliberately narrow aggregate commands: each locks
-- the parent row, checks ownership and expected_revision, and commits one revision.

create or replace function public.itinerary_idempotency_result(
  p_user_id uuid,
  p_operation text,
  p_idempotency_key uuid,
  p_request_hash bytea
)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare existing_hash bytea; existing_result jsonb; inserted boolean;
begin
  if p_idempotency_key is null then raise exception using errcode = '22023', message = 'idempotency_key is required'; end if;
  insert into public.trip_idempotency_keys(user_id, operation, idempotency_key, request_hash)
  values (p_user_id, p_operation, p_idempotency_key, p_request_hash)
  on conflict (user_id, operation, idempotency_key) do nothing;
  inserted := found;
  if not inserted then
    select request_hash, result into existing_hash, existing_result from public.trip_idempotency_keys
    where user_id = p_user_id and operation = p_operation and idempotency_key = p_idempotency_key;
    if existing_hash <> p_request_hash then raise exception using errcode = '22023', message = 'idempotency key was reused with different request data'; end if;
    if existing_result is not null then return existing_result; end if;
  end if;
  return null;
end;
$$;

create or replace function public.store_itinerary_idempotency_result(p_user_id uuid, p_operation text, p_idempotency_key uuid, p_result jsonb)
returns void language sql security definer set search_path = public, pg_temp
as $$ update public.trip_idempotency_keys set result = p_result where user_id = p_user_id and operation = p_operation and idempotency_key = p_idempotency_key; $$;

create or replace function public.create_trip(
  p_idempotency_key uuid, p_title varchar(80), p_timezone text default 'Asia/Shanghai',
  p_start_date date default null, p_end_date date default null, p_party_size smallint default 1,
  p_currency_code char(3) default 'CNY', p_budget_limit_minor bigint default null,
  p_budget_scope text default null, p_default_travel_mode text default 'walking')
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare actor uuid := (select auth.uid()); request_hash bytea; prior jsonb; created public.trips%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  if p_start_date is null or p_end_date is null then raise exception using errcode = '22023', message = 'trip dates are required'; end if;
  request_hash := digest(jsonb_build_object('title',p_title,'timezone',p_timezone,'start_date',p_start_date,'end_date',p_end_date,'party_size',p_party_size,'currency_code',p_currency_code,'budget_limit_minor',p_budget_limit_minor,'budget_scope',p_budget_scope,'default_travel_mode',p_default_travel_mode)::text,'sha256');
  prior := public.itinerary_idempotency_result(actor, 'create_trip', p_idempotency_key, request_hash); if prior is not null then return prior; end if;
  insert into public.trips(user_id,title,timezone,start_date,end_date,party_size,currency_code,budget_limit_minor,budget_scope,default_travel_mode)
  values(actor,p_title,p_timezone,p_start_date,p_end_date,p_party_size,p_currency_code,p_budget_limit_minor,p_budget_scope,p_default_travel_mode) returning * into created;
  result := to_jsonb(created); perform public.store_itinerary_idempotency_result(actor,'create_trip',p_idempotency_key,result); return result;
end;
$$;

create or replace function public.add_trip_day(
  p_trip_id uuid, p_expected_revision bigint, p_idempotency_key uuid, p_local_date date,
  p_available_start_time time default null, p_available_end_time time default null,
  p_budget_limit_minor bigint default null, p_notes varchar(1000) default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare actor uuid := (select auth.uid()); request_hash bytea; prior jsonb; trip_row public.trips%rowtype; created public.trip_days%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  request_hash := digest(jsonb_build_object('trip_id',p_trip_id,'local_date',p_local_date,'available_start_time',p_available_start_time,'available_end_time',p_available_end_time,'budget_limit_minor',p_budget_limit_minor,'notes',p_notes)::text,'sha256');
  prior := public.itinerary_idempotency_result(actor,'add_trip_day',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into trip_row from public.trips where id=p_trip_id and user_id=actor for update;
  if not found then raise exception using errcode = '42501', message = 'trip not found'; end if;
  if trip_row.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'trip revision conflict'; end if;
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
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare actor uuid := (select auth.uid()); request_hash bytea; prior jsonb; trip_row public.trips%rowtype; created public.trip_items%rowtype; result jsonb;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  request_hash := digest(jsonb_build_object('trip_id',p_trip_id,'trip_day_id',p_trip_day_id,'item_type',p_item_type,'place_id',p_place_id,'title',p_title,'planned_start_at',p_planned_start_at,'planned_end_at',p_planned_end_at,'time_slot',p_time_slot,'position',p_position,'estimated_cost_min_minor',p_estimated_cost_min_minor,'estimated_cost_max_minor',p_estimated_cost_max_minor,'notes',p_notes,'place_snapshot',p_place_snapshot)::text,'sha256');
  prior := public.itinerary_idempotency_result(actor,'add_trip_item',p_idempotency_key,request_hash); if prior is not null then return prior; end if;
  select * into trip_row from public.trips where id=p_trip_id and user_id=actor for update;
  if not found then raise exception using errcode = '42501', message = 'trip not found'; end if;
  if trip_row.revision <> p_expected_revision then raise exception using errcode = '40001', message = 'trip revision conflict'; end if;
  insert into public.trip_items(trip_id,trip_day_id,item_type,place_id,title,planned_start_at,planned_end_at,time_slot,position,estimated_cost_min_minor,estimated_cost_max_minor,notes,place_snapshot)
  values(p_trip_id,p_trip_day_id,p_item_type,p_place_id,p_title,p_planned_start_at,p_planned_end_at,p_time_slot,p_position,p_estimated_cost_min_minor,p_estimated_cost_max_minor,p_notes,p_place_snapshot) returning * into created;
  update public.trips set revision=revision+1 where id=p_trip_id;
  result := jsonb_build_object('trip_item',to_jsonb(created),'revision',trip_row.revision+1); perform public.store_itinerary_idempotency_result(actor,'add_trip_item',p_idempotency_key,result); return result;
end;
$$;

revoke all on function public.itinerary_idempotency_result(uuid,text,uuid,bytea) from public, anon, authenticated;
revoke all on function public.store_itinerary_idempotency_result(uuid,text,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.create_trip(uuid,varchar,text,date,date,smallint,char,bigint,text,text) from public, anon, authenticated;
revoke all on function public.add_trip_day(uuid,bigint,uuid,date,time,time,bigint,varchar) from public, anon, authenticated;
revoke all on function public.add_trip_item(uuid,bigint,uuid,uuid,text,uuid,varchar,timestamptz,timestamptz,text,integer,bigint,bigint,varchar,jsonb) from public, anon, authenticated;
grant execute on function public.create_trip(uuid,varchar,text,date,date,smallint,char,bigint,text,text) to authenticated;
grant execute on function public.add_trip_day(uuid,bigint,uuid,date,time,time,bigint,varchar) to authenticated;
grant execute on function public.add_trip_item(uuid,bigint,uuid,uuid,text,uuid,varchar,timestamptz,timestamptz,text,integer,bigint,bigint,varchar,jsonb) to authenticated;
