-- Remaining captain commands that do not belong in the itinerary aggregate.

-- The orchestrator is the only component allowed to use service_role. Keep the
-- grant conditional so this migration remains usable in generic PostgreSQL
-- fixtures that do not create Supabase's service_role role.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update on public.squad_sessions, public.captain_commands,
      public.agent_plans, public.agent_tasks, public.agent_steps,
      public.agent_artifacts, public.squad_events, public.decision_checkpoints,
      public.memory_proposals, public.recommendation_sets, public.trip_drafts,
      public.user_memories, public.recommendation_feedbacks, public.places
      to service_role;
    grant execute on function public.append_squad_event(uuid, uuid, uuid, text, text, jsonb, text)
      to service_role;
  end if;
end;
$$;

create or replace function public.retry_agent_task(p_task_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  task_row public.agent_tasks%rowtype;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  select t.* into task_row
  from public.agent_tasks t
  where t.id = p_task_id
    and exists (select 1 from public.squad_sessions s where s.id = t.session_id and s.user_id = actor)
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'task not found';
  end if;
  if task_row.status not in ('failed', 'timed_out', 'partial') then
    raise exception using errcode = '22023', message = 'task is not retryable';
  end if;

  update public.agent_tasks
  set status = 'queued', progress = 0, error_code = null,
      finished_at = null, version = version + 1
  where id = p_task_id;
  update public.agent_plans set status = 'running' where id = task_row.plan_id;
  update public.squad_sessions set status = 'working' where id = task_row.session_id;
  perform public.append_squad_event(
    task_row.session_id, task_row.command_id, task_row.id, 'task.created', 'captain',
    jsonb_build_object('retry', true, 'taskId', task_row.id)
  );
  return jsonb_build_object(
    'taskId', task_row.id, 'sessionId', task_row.session_id,
    'commandId', task_row.command_id, 'status', 'queued'
  );
end;
$$;

revoke all on function public.retry_agent_task(uuid) from public, anon, authenticated;
grant execute on function public.retry_agent_task(uuid) to authenticated;
