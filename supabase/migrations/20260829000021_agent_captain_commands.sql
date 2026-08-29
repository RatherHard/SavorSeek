-- Agent squad persistence additions: user memories, recommendation
-- selections and feedback, plus the captain-facing RPCs that close the
-- Phase E loop (select / reject / feedback / memory decision /
-- checkpoint resolution / trip draft application).
--
-- All RPCs are security definer and derive ownership from auth.uid().

create table if not exists public.user_memories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  memory_key varchar(120) not null,
  memory_value jsonb not null,
  source text not null default 'captain_confirmed',
  confidence numeric(5,4),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_memories_user_key_uq unique (user_id, memory_key),
  constraint user_memories_key_ck check (char_length(btrim(memory_key)) between 1 and 120),
  constraint user_memories_value_ck check (jsonb_typeof(memory_value) = 'object'),
  constraint user_memories_source_ck check (source in ('captain_confirmed', 'explicit_input', 'feedback_derived')),
  constraint user_memories_confidence_ck check (confidence is null or confidence between 0 and 1)
);

create table if not exists public.recommendation_feedbacks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid references public.squad_sessions(id) on delete cascade,
  recommendation_set_id uuid not null references public.recommendation_sets(id) on delete cascade,
  place_name varchar(120) not null,
  feedback text not null,
  created_at timestamptz not null default now(),
  constraint recommendation_feedbacks_kind_ck check (feedback in ('liked', 'disliked', 'inaccurate')),
  constraint recommendation_feedbacks_name_ck check (char_length(btrim(place_name)) between 1 and 120)
);

create index if not exists user_memories_user_updated_idx
  on public.user_memories (user_id, updated_at desc);
create index if not exists recommendation_feedbacks_user_created_idx
  on public.recommendation_feedbacks (user_id, created_at desc);

create or replace function public.touch_user_memories_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger user_memories_updated_at before update on public.user_memories
for each row execute function public.touch_user_memories_updated_at();

alter table public.user_memories enable row level security;
alter table public.recommendation_feedbacks enable row level security;

create policy user_memories_select_own on public.user_memories
  for select to authenticated using (user_id = auth.uid());
create policy user_memories_all_own on public.user_memories
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy recommendation_feedbacks_select_own on public.recommendation_feedbacks
  for select to authenticated using (user_id = auth.uid());

revoke all on public.user_memories, public.recommendation_feedbacks
  from anon, authenticated;
grant select on public.user_memories, public.recommendation_feedbacks to authenticated;


-- 通用化幂等表：apply_trip_draft 的载荷不是 command，经 result 列存取。
alter table public.agent_command_idempotency_keys
  add column if not exists result jsonb;

-- ───────────────────────── helper: session ownership ─────────────────────────

create or replace function public.agent_assert_session_owner(
  p_session_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if not exists (
    select 1 from public.squad_sessions s
    where s.id = p_session_id and s.user_id = actor
  ) then
    raise exception using errcode = '42501', message = 'session not found';
  end if;
end;
$$;

-- ───────────────────────── recommendation commands ───────────────────────────

create or replace function public.select_recommendation(
  p_session_id uuid,
  p_recommendation_set_id uuid,
  p_place_names text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  updated integer;
begin
  perform public.agent_assert_session_owner(p_session_id);

  update public.recommendation_sets
  set status = 'captain_selected',
      selected_place_ids = coalesce(selected_place_ids, '{}'::uuid[]),
      items = (
        select coalesce(jsonb_agg(
          case when (item->>'name') = any(p_place_names)
            then jsonb_set(item, '{status}', '"captain_selected"')
            else item end
          order by (item->>'rank')::int
        ), '[]'::jsonb)
        from jsonb_array_elements(items) item
      )
  where id = p_recommendation_set_id
    and session_id = p_session_id
    and status in ('generated', 'displayed');
  get diagnostics updated = row_count;
  if updated = 0 then
    raise exception using errcode = '22023', message = 'recommendation set not selectable';
  end if;

  perform public.append_squad_event(
    p_session_id, null, null, 'recommendation.proposed', 'captain',
    jsonb_build_object('action', 'captain_selected', 'places', p_place_names)
  );
  return jsonb_build_object('status', 'captain_selected', 'selected', p_place_names);
end;
$$;

create or replace function public.reject_recommendation(
  p_session_id uuid,
  p_recommendation_set_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.agent_assert_session_owner(p_session_id);
  update public.recommendation_sets
  set status = 'rejected'
  where id = p_recommendation_set_id
    and session_id = p_session_id
    and status in ('generated', 'displayed', 'captain_selected');
  if not found then
    raise exception using errcode = '22023', message = 'recommendation set not rejectable';
  end if;
  perform public.append_squad_event(
    p_session_id, null, null, 'recommendation.proposed', 'captain',
    jsonb_build_object('action', 'rejected', 'recommendationSetId', p_recommendation_set_id)
  );
  return jsonb_build_object('status', 'rejected');
end;
$$;

create or replace function public.submit_recommendation_feedback(
  p_session_id uuid,
  p_recommendation_set_id uuid,
  p_place_name varchar(120),
  p_feedback text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
begin
  perform public.agent_assert_session_owner(p_session_id);
  if p_feedback not in ('liked', 'disliked', 'inaccurate') then
    raise exception using errcode = '22023', message = 'invalid feedback kind';
  end if;
  if not exists (
    select 1 from public.recommendation_sets
    where id = p_recommendation_set_id and session_id = p_session_id
  ) then
    raise exception using errcode = '22023', message = 'recommendation set not found';
  end if;
  insert into public.recommendation_feedbacks(user_id, session_id, recommendation_set_id, place_name, feedback)
  values (actor, p_session_id, p_recommendation_set_id, p_place_name, p_feedback);

  -- 反馈派生偏好：liked 直接写入低置信度记忆（可撤销），disliked/inaccurate 只落反馈记录。
  if p_feedback = 'liked' then
    insert into public.user_memories(user_id, memory_key, memory_value, source, confidence)
    values (
      actor,
      'liked_place:' || p_place_name,
      jsonb_build_object('placeName', p_place_name, 'note', '来自推荐反馈'),
      'feedback_derived', 0.6
    )
    on conflict (user_id, memory_key) do update
      set updated_at = now();
    perform public.append_squad_event(
      p_session_id, null, null, 'memory.updated', 'captain',
      jsonb_build_object('action', 'liked', 'place', p_place_name)
    );
  end if;
  return jsonb_build_object('recorded', true, 'feedback', p_feedback);
end;
$$;

-- ───────────────────────── memory proposal decision ──────────────────────────

create or replace function public.resolve_memory_proposal(
  p_proposal_id uuid,
  p_decision text,
  p_edited_value jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  proposal public.memory_proposals%rowtype;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_decision not in ('accept', 'reject', 'edit') then
    raise exception using errcode = '22023', message = 'invalid memory decision';
  end if;

  select * into proposal
  from public.memory_proposals m
  where m.id = p_proposal_id and m.user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'memory proposal not found';
  end if;
  if proposal.status in ('accepted', 'rejected', 'edited', 'expired') then
    raise exception using errcode = '22023', message = 'memory proposal already resolved';
  end if;
  if p_decision = 'edit' and (p_edited_value is null or jsonb_typeof(p_edited_value) <> 'object') then
    raise exception using errcode = '22023', message = 'edited memory value required';
  end if;

  if p_decision = 'accept' then
    perform public.apply_memory_operation(actor, proposal.operation, proposal.memory_key, proposal.proposed_value);
    update public.memory_proposals set status = 'accepted', resolved_at = now()
    where id = p_proposal_id;
  elsif p_decision = 'edit' then
    perform public.apply_memory_operation(actor, proposal.operation, proposal.memory_key, p_edited_value);
    update public.memory_proposals set status = 'edited', captain_value = p_edited_value, resolved_at = now()
    where id = p_proposal_id;
  else
    update public.memory_proposals set status = 'rejected', resolved_at = now()
    where id = p_proposal_id;
  end if;

  perform public.append_squad_event(
    proposal.session_id, null, null, 'memory.updated', 'captain',
    jsonb_build_object('proposalId', p_proposal_id, 'decision', p_decision, 'memoryKey', proposal.memory_key)
  );
  return jsonb_build_object('proposalId', p_proposal_id, 'status',
    case p_decision when 'accept' then 'accepted' when 'edit' then 'edited' else 'rejected' end);
end;
$$;


create or replace function public.agent_idempotency_begin_result(
  p_user_id uuid,
  p_operation text,
  p_idempotency_key uuid,
  p_request_hash bytea
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  existing_hash bytea;
  existing_result jsonb;
begin
  if p_idempotency_key is null then
    raise exception using errcode = '22023', message = 'idempotency_key is required';
  end if;
  insert into public.agent_command_idempotency_keys(user_id, client_request_id, request_hash)
  values (p_user_id, p_idempotency_key, p_request_hash)
  on conflict (user_id, client_request_id) do nothing;

  select request_hash, result into existing_hash, existing_result
  from public.agent_command_idempotency_keys
  where user_id = p_user_id and client_request_id = p_idempotency_key
  for update;

  if existing_hash <> p_request_hash then
    raise exception using
      errcode = '22023', message = 'idempotency key was reused with different request data';
  end if;
  return existing_result;
end;
$$;

create or replace function public.agent_idempotency_store_result(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_result jsonb
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.agent_command_idempotency_keys
  set result = p_result
  where user_id = p_user_id and client_request_id = p_idempotency_key;
$$;

create or replace function public.apply_memory_operation(
  p_user_id uuid,
  p_operation text,
  p_memory_key varchar(120),
  p_value jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_operation = 'delete' then
    delete from public.user_memories
    where user_id = p_user_id and memory_key = p_memory_key;
  else
    insert into public.user_memories(user_id, memory_key, memory_value, source, confidence)
    values (p_user_id, p_memory_key, p_value, 'captain_confirmed', null)
    on conflict (user_id, memory_key) do update
      set memory_value = excluded.memory_value, updated_at = now();
  end if;
end;
$$;

-- ───────────────────────── decision checkpoints ──────────────────────────────

create or replace function public.resolve_decision_checkpoint(
  p_checkpoint_id uuid,
  p_selected_option_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  checkpoint public.decision_checkpoints%rowtype;
  option jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  select * into checkpoint
  from public.decision_checkpoints d
  where d.id = p_checkpoint_id
    and exists (select 1 from public.squad_sessions s where s.id = d.session_id and s.user_id = actor)
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'checkpoint not found';
  end if;
  if checkpoint.status <> 'pending' then
    raise exception using errcode = '22023', message = 'checkpoint already resolved';
  end if;

  select opt into option
  from jsonb_array_elements(checkpoint.options) opt
  where opt->>'id' = p_selected_option_id;
  if option is null then
    raise exception using errcode = '22023', message = 'unknown option id';
  end if;

  update public.decision_checkpoints
  set status = case when p_selected_option_id = 'cancel' then 'rejected' else 'accepted' end,
      selected_option_id = p_selected_option_id,
      resolved_at = now()
  where id = p_checkpoint_id;

  perform public.append_squad_event(
    checkpoint.session_id, null, checkpoint.task_id, 'decision.resolved', 'captain',
    jsonb_build_object('checkpointId', p_checkpoint_id, 'option', p_selected_option_id)
  );
  return jsonb_build_object('checkpointId', p_checkpoint_id, 'selectedOption', p_selected_option_id);
end;
$$;

-- ───────────────────────── trip draft application ────────────────────────────

create or replace function public.apply_trip_draft(
  p_draft_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := auth.uid();
  draft public.trip_drafts%rowtype;
  trip_row public.trips%rowtype;
  request_hash bytea;
  prior jsonb;
  day_id uuid;
  item_row public.trip_items%rowtype;
  new_revision bigint;
  created_count integer := 0;
  day_cache jsonb := '{}'::jsonb;
  draft_item jsonb;
  draft_day date;
  planned_start timestamptz;
  planned_end timestamptz;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_idempotency_key is null then
    raise exception using errcode = '22023', message = 'idempotency_key is required';
  end if;
  request_hash := digest(jsonb_build_object('draftId', p_draft_id, 'expectedRevision', p_expected_revision)::text, 'sha256');
  prior := public.agent_idempotency_begin_result(actor, 'apply_trip_draft', p_idempotency_key, request_hash);
  if prior is not null then
    return jsonb_build_object('alreadyApplied', true, 'tripId', prior->>'tripId');
  end if;

  select * into draft
  from public.trip_drafts d
  where d.id = p_draft_id
    and exists (select 1 from public.trips t where t.id = d.trip_id and t.user_id = actor)
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip draft not found';
  end if;
  if draft.status in ('applied', 'rejected', 'expired') then
    raise exception using errcode = '22023', message = 'trip draft already resolved';
  end if;

  select * into trip_row from public.trips where id = draft.trip_id for update;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'trip revision conflict';
  end if;

  -- 草案日期必须落在行程范围内。
  for draft_item in select * from jsonb_array_elements(draft.items) loop
    draft_day := (draft_item->>'localDate')::date;
    if draft_day < trip_row.start_date or draft_day > trip_row.end_date then
      raise exception using errcode = '23514', message = 'draft day outside trip date range';
    end if;
  end loop;

  -- 写入行程项：复用行程触发器校验（快照结构/锁定/终态），保持单一事实源。
  for draft_item in select * from jsonb_array_elements(draft.items) loop
    draft_day := (draft_item->>'localDate')::date;
    planned_start := (draft_item->>'plannedStartAt')::timestamptz;
    planned_end := (draft_item->>'plannedEndAt')::timestamptz;
    if day_cache ->> (draft_item->>'localDate') is not null then
      day_id := (day_cache ->> (draft_item->>'localDate'))::uuid;
    else
      select id into day_id from public.trip_days
      where trip_id = draft.trip_id
        and trip_days.local_date = (draft_item->>'localDate')::date;
      if day_id is null then
        insert into public.trip_days(trip_id, local_date)
        values (draft.trip_id, draft_day)
        returning id into day_id;
      end if;
      day_cache := day_cache || jsonb_build_object(draft_item->>'localDate', day_id);
    end if;

    insert into public.trip_items(
      trip_id, trip_day_id, item_type, place_id, title,
      planned_start_at, planned_end_at, time_slot, position,
      estimated_cost_min_minor, estimated_cost_max_minor,
      created_by, source_agent_task_id, place_snapshot
    ) values (
      draft.trip_id, day_id,
      coalesce(draft_item->>'itemType', 'place_visit'),
      (draft_item->>'placeId')::uuid,
      coalesce(draft_item->>'title', '美食到访'),
      planned_start, planned_end,
      coalesce(draft_item->>'timeSlot', 'flexible'),
      coalesce((draft_item->>'position')::int, 0),
      (draft_item->>'estimatedCostMinMinor')::bigint,
      (draft_item->>'estimatedCostMaxMinor')::bigint,
      'agent', draft.source_task_id,
      draft_item->'placeSnapshot'
    ) returning * into item_row;
    created_count := created_count + 1;
  end loop;

  update public.trips set revision = revision + 1 where id = draft.trip_id
    returning revision into new_revision;
  update public.trip_drafts set status = 'applied', updated_at = now()
    where id = p_draft_id;
  perform public.agent_idempotency_store_result(actor, p_idempotency_key, jsonb_build_object('tripId', draft.trip_id, 'revision', new_revision, 'itemsCreated', created_count));

  perform public.append_squad_event(
    draft.session_id, null, draft.source_task_id, 'trip.updated', 'orchestrator',
    jsonb_build_object('tripId', draft.trip_id, 'draftId', p_draft_id,
                       'revision', new_revision, 'itemsCreated', created_count)
  );
  return jsonb_build_object('tripId', draft.trip_id, 'revision', new_revision, 'itemsCreated', created_count);
end;
$$;

revoke all on function
  public.agent_assert_session_owner(uuid),
  public.select_recommendation(uuid, uuid, text[]),
  public.reject_recommendation(uuid, uuid),
  public.submit_recommendation_feedback(uuid, uuid, varchar, text),
  public.resolve_memory_proposal(uuid, text, jsonb),
  public.apply_memory_operation(uuid, text, varchar, jsonb),
  public.resolve_decision_checkpoint(uuid, text),
  public.apply_trip_draft(uuid, bigint, uuid)
from public, anon, authenticated;

grant execute on function
  public.select_recommendation(uuid, uuid, text[]),
  public.reject_recommendation(uuid, uuid),
  public.submit_recommendation_feedback(uuid, uuid, varchar, text),
  public.resolve_memory_proposal(uuid, text, jsonb),
  public.resolve_decision_checkpoint(uuid, text),
  public.apply_trip_draft(uuid, bigint, uuid)
to authenticated;
