-- Agent squad command surface: idempotent command submission with request
-- hashing, monotonic session event sequences, session cancellation and
-- event catch-up queries.
--
-- These RPCs are security definer and derive every ownership check from
-- auth.uid(); base-table DML stays revoked from client roles.

create or replace function public.agent_idempotency_begin(
  p_user_id uuid,
  p_operation text,
  p_idempotency_key uuid,
  p_request_hash bytea
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  existing_hash bytea;
  existing_command_id text;
begin
  if p_idempotency_key is null then
    raise exception using errcode = '22023', message = 'idempotency_key is required';
  end if;
  insert into public.agent_command_idempotency_keys(user_id, client_request_id, request_hash)
  values (p_user_id, p_idempotency_key, p_request_hash)
  on conflict (user_id, client_request_id) do nothing;

  select request_hash, command_id::text into existing_hash, existing_command_id
  from public.agent_command_idempotency_keys
  where user_id = p_user_id and client_request_id = p_idempotency_key
  for update;

  if existing_hash <> p_request_hash then
    raise exception using
      errcode = '22023', message = 'idempotency key was reused with different request data';
  end if;
  return existing_command_id;
end;
$$;

create or replace function public.agent_idempotency_store(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_command_id uuid
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.agent_command_idempotency_keys
  set command_id = p_command_id
  where user_id = p_user_id and client_request_id = p_idempotency_key;
$$;

create or replace function public.agent_session_next_sequence(
  p_session_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  next_seq bigint;
begin
  -- Row lock on the session serializes concurrent appenders so the per-session
  -- sequence stays gap-free and monotonic even with parallel steps.
  select coalesce(max(e.sequence), 0) + 1 into next_seq
  from public.squad_events e
  where e.session_id = p_session_id;

  return next_seq;
end;
$$;

create or replace function public.append_squad_event(
  p_session_id uuid,
  p_command_id uuid,
  p_task_id uuid,
  p_event_type text,
  p_actor text,
  p_payload jsonb default '{}'::jsonb,
  p_visibility text default 'captain'
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  inserted_sequence bigint;
begin
  if p_actor not in ('captain', 'agent', 'orchestrator', 'system', 'external_source') then
    raise exception using errcode = '22023', message = 'invalid event actor';
  end if;
  if p_visibility not in ('captain', 'internal') then
    raise exception using errcode = '22023', message = 'invalid event visibility';
  end if;

  -- Lock the parent session row first: every appender takes this lock before
  -- computing max(sequence), so sequences are allocated under serialization.
  perform 1 from public.squad_sessions s where s.id = p_session_id for update;

  insert into public.squad_events(session_id, command_id, task_id, sequence, event_type, actor, payload, visibility)
  values (p_session_id, p_command_id, p_task_id, (select public.agent_session_next_sequence(p_session_id)), p_event_type, p_actor, p_payload, p_visibility)
  returning sequence into inserted_sequence;

  update public.squad_sessions
  set projection_version = projection_version + 1
  where id = p_session_id;

  return inserted_sequence;
end;
$$;

create or replace function public.submit_captain_command(
  p_client_request_id uuid,
  p_title varchar(120),
  p_goal varchar(2000),
  p_raw_text varchar(2000),
  p_task_type text,
  p_context jsonb default '{}'::jsonb,
  p_constraints jsonb default '{}'::jsonb,
  p_memory_policy text default 'propose_only',
  p_locale text default 'zh-CN',
  p_client_version varchar(64) default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  request_hash bytea;
  prior_command_id uuid;
  session_row public.squad_sessions%rowtype;
  command_row public.captain_commands%rowtype;
  plan_row public.agent_plans%rowtype;
  task_row public.agent_tasks%rowtype;
  seq bigint;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_context is null or jsonb_typeof(p_context) <> 'object' then
    raise exception using errcode = '22023', message = 'context must be an object';
  end if;
  if p_constraints is null or jsonb_typeof(p_constraints) <> 'object' then
    raise exception using errcode = '22023', message = 'constraints must be an object';
  end if;

  request_hash := extensions.digest(
    jsonb_build_object(
      'title', p_title, 'goal', p_goal, 'raw_text', p_raw_text,
      'task_type', p_task_type, 'context', p_context, 'constraints', p_constraints,
      'memory_policy', p_memory_policy, 'locale', p_locale, 'client_version', p_client_version
    )::text, 'sha256'::text
  );
  prior_command_id := public.agent_idempotency_begin(actor, 'submit_captain_command', p_client_request_id, request_hash);
  if prior_command_id is not null then
    return jsonb_build_object('sessionId', c.session_id, 'commandId', c.id, 'status', c.status)
      from public.captain_commands c where c.id = prior_command_id;
  end if;

  insert into public.squad_sessions(user_id, title, goal, status, map_context, trip_context)
  values (
    actor, p_title, p_goal, 'receiving_command',
    coalesce(p_context->'mapViewport', '{}'::jsonb),
    jsonb_build_object('tripId', p_context->>'tripId', 'tripRevision', p_context->>'tripRevision')
  )
  returning * into session_row;

  insert into public.captain_commands(
    user_id, session_id, client_request_id, raw_text, task_type,
    context, constraints_json, memory_policy, locale, client_version
  )
  values (
    actor, session_row.id, p_client_request_id, p_raw_text, p_task_type,
    p_context, p_constraints, p_memory_policy, p_locale, p_client_version
  )
  returning * into command_row;

  update public.squad_sessions
  set active_command_id = command_row.id, status = 'dispatching'
  where id = session_row.id;

  insert into public.agent_plans(command_id, session_id, status)
  values (command_row.id, session_row.id, 'queued')
  returning * into plan_row;

  insert into public.agent_tasks(plan_id, session_id, command_id, role, status, user_summary)
  values (plan_row.id, session_row.id, command_row.id, 'result_coordinator', 'queued', '正在准备小队任务')
  returning * into task_row;

  perform public.agent_idempotency_store(actor, p_client_request_id, command_row.id);

  seq := public.append_squad_event(session_row.id, command_row.id, null, 'session.created', 'orchestrator', jsonb_build_object('sessionId', session_row.id));
  seq := public.append_squad_event(session_row.id, command_row.id, null, 'command.accepted', 'orchestrator', jsonb_build_object('commandId', command_row.id));
  return jsonb_build_object(
    'sessionId', session_row.id,
    'commandId', command_row.id,
    'planId', plan_row.id,
    'taskId', task_row.id,
    'lastSequence', seq,
    'status', 'accepted'
  );
end;
$$;

create or replace function public.cancel_squad_session(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  session_row public.squad_sessions%rowtype;
  command_row public.captain_commands%rowtype;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  select * into session_row
  from public.squad_sessions s
  where s.id = p_session_id and s.user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'session not found';
  end if;

  if session_row.status in ('completed', 'cancelled', 'failed', 'timed_out') then
    raise exception using errcode = '22023', message = 'session already in terminal status ' || session_row.status;
  end if;

  -- Running external work is told to stop via the cancelling transition; the
  -- orchestrator worker decides when running steps actually drain. No new
  -- step may start after this commit.
  update public.agent_tasks t
  set status = case when t.status in ('queued', 'assigned', 'waiting_for_dependency', 'waiting_for_captain') then 'cancelled' else t.status end
  where t.session_id = session_row.id and t.status not in ('succeeded', 'failed', 'timed_out', 'cancelled');

  update public.captain_commands c
  set status = 'cancelled'
  where c.session_id = session_row.id and c.status in ('accepted', 'processing');

  update public.squad_sessions
  set status = 'cancelled'
  where id = session_row.id
  returning * into session_row;

  select * into command_row
  from public.captain_commands c
  where c.id = session_row.active_command_id;

  perform public.append_squad_event(
    session_row.id, command_row.id, null, 'session.cancelled', 'captain',
    jsonb_build_object('sessionId', session_row.id, 'commandId', command_row.id)
  );

  return jsonb_build_object('sessionId', session_row.id, 'status', session_row.status);
end;
$$;

create or replace function public.list_squad_events(
  p_session_id uuid,
  p_after_sequence bigint default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  events jsonb;
  last_seq bigint;
  next_cursor bigint;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception using errcode = '22023', message = 'event page limit must be between 1 and 500';
  end if;

  if not exists (
    select 1 from public.squad_sessions s
    where s.id = p_session_id and s.user_id = actor
  ) then
    raise exception using errcode = '42501', message = 'session not found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'eventId', e.id,
    'sequence', e.sequence,
    'eventType', e.event_type,
    'commandId', e.command_id,
    'taskId', e.task_id,
    'occurredAt', e.occurred_at,
    'actor', e.actor,
    'payload', e.payload
  ) order by e.sequence), '[]'::jsonb)
  into events
  from (
    select e.*
    from public.squad_events e
    where e.session_id = p_session_id
      and e.visibility = 'captain'
      and (p_after_sequence is null or e.sequence > p_after_sequence)
    order by e.sequence
    limit p_limit
  ) e;

  select max((ev->>'sequence')::bigint) into last_seq from jsonb_array_elements(events) ev;

  if last_seq is null then
    select coalesce(max(e.sequence), 0) into last_seq
    from public.squad_events e
    where e.session_id = p_session_id and e.visibility = 'captain'
      and (p_after_sequence is null or e.sequence <= p_after_sequence);
    next_cursor := p_after_sequence;
  else
    next_cursor := last_seq;
  end if;

  return jsonb_build_object('events', events, 'nextSequence', coalesce(next_cursor, 0));
end;
$$;

revoke all on function
  public.agent_idempotency_begin(uuid, text, uuid, bytea),
  public.agent_idempotency_store(uuid, uuid, uuid),
  public.agent_session_next_sequence(uuid),
  public.append_squad_event(uuid, uuid, uuid, text, text, jsonb, text),
  public.submit_captain_command(uuid, varchar, varchar, varchar, text, jsonb, jsonb, text, text, varchar),
  public.cancel_squad_session(uuid),
  public.list_squad_events(uuid, bigint, integer)
from public, anon, authenticated;

grant execute on function public.submit_captain_command(uuid, varchar, varchar, varchar, text, jsonb, jsonb, text, text, varchar) to authenticated;
grant execute on function public.cancel_squad_session(uuid) to authenticated;
grant execute on function public.list_squad_events(uuid, bigint, integer) to authenticated;
