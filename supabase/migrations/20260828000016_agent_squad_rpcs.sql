-- Narrow authenticated commands for the Agent squad aggregate.

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
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  existing public.captain_commands%rowtype;
  session_row public.squad_sessions%rowtype;
  command_row public.captain_commands%rowtype;
  plan_row public.agent_plans%rowtype;
  task_row public.agent_tasks%rowtype;
  request_hash bytea;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  if p_client_request_id is null then raise exception using errcode = '22023', message = 'client_request_id is required'; end if;
  if p_context is null or jsonb_typeof(p_context) <> 'object' then raise exception using errcode = '22023', message = 'context must be an object'; end if;
  if p_constraints is null or jsonb_typeof(p_constraints) <> 'object' then raise exception using errcode = '22023', message = 'constraints must be an object'; end if;

  request_hash := digest(jsonb_build_object('title',p_title,'goal',p_goal,'raw_text',p_raw_text,'task_type',p_task_type,'context',p_context,'constraints',p_constraints,'memory_policy',p_memory_policy,'locale',p_locale,'client_version',p_client_version)::text, 'sha256');
  select c.* into existing from public.captain_commands c where c.user_id = actor and c.client_request_id = p_client_request_id;
  if found then
    if existing.raw_text <> p_raw_text or existing.task_type <> p_task_type or existing.context <> p_context or existing.constraints_json <> p_constraints or existing.memory_policy <> p_memory_policy or existing.locale <> p_locale or existing.client_version is distinct from p_client_version then
      raise exception using errcode = '22023', message = 'client_request_id was reused with different request data';
    end if;
    return jsonb_build_object('sessionId', existing.session_id, 'commandId', existing.id, 'status', existing.status);
  end if;

  insert into public.squad_sessions(user_id, title, goal, status, map_context, trip_context)
  values (actor, p_title, p_goal, 'receiving_command', coalesce(p_context->'mapViewport','{}'::jsonb), jsonb_build_object('tripId',p_context->>'tripId','tripRevision',p_context->>'tripRevision'))
  returning * into session_row;

  insert into public.captain_commands(user_id, session_id, client_request_id, raw_text, task_type, context, constraints_json, memory_policy, locale, client_version)
  values (actor, session_row.id, p_client_request_id, p_raw_text, p_task_type, p_context, p_constraints, p_memory_policy, p_locale, p_client_version)
  returning * into command_row;

  update public.squad_sessions set active_command_id = command_row.id, status = 'dispatching' where id = session_row.id;
  insert into public.agent_plans(command_id, session_id, status) values (command_row.id, session_row.id, 'queued') returning * into plan_row;
  insert into public.agent_tasks(plan_id, session_id, command_id, role, status, user_summary)
  values (plan_row.id, session_row.id, command_row.id, 'result_coordinator', 'queued', '正在准备小队任务') returning * into task_row;
  insert into public.squad_events(session_id, command_id, sequence, event_type, actor, payload)
  values (session_row.id, command_row.id, 1, 'session.created', 'orchestrator', jsonb_build_object('sessionId',session_row.id));
  insert into public.squad_events(session_id, command_id, sequence, event_type, actor, payload)
  values (session_row.id, command_row.id, 2, 'command.accepted', 'orchestrator', jsonb_build_object('commandId',command_row.id));
  return jsonb_build_object('sessionId', session_row.id, 'commandId', command_row.id, 'planId', plan_row.id, 'taskId', task_row.id, 'status', 'accepted');
end;
$$;

create or replace function public.get_squad_session_projection(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare actor uuid := auth.uid(); result jsonb;
begin
  if actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  select jsonb_build_object(
    'session', to_jsonb(s),
    'commands', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.captain_commands c where c.session_id=s.id), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at) from public.agent_plans p where p.session_id=s.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.agent_tasks t where t.session_id=s.id), '[]'::jsonb),
    'artifacts', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.agent_artifacts a where a.session_id=s.id and a.is_captain_visible), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.sequence) from public.squad_events e where e.session_id=s.id and e.visibility='captain'), '[]'::jsonb),
    'decisions', coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at) from public.decision_checkpoints d where d.session_id=s.id), '[]'::jsonb),
    'recommendations', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.recommendation_sets r where r.session_id=s.id), '[]'::jsonb),
    'drafts', coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at) from public.trip_drafts d where d.session_id=s.id), '[]'::jsonb)
  ) into result from public.squad_sessions s where s.id=p_session_id and s.user_id=actor;
  if result is null then raise exception using errcode = '42501', message = 'session not found'; end if;
  return result;
end;
$$;

revoke all on function public.submit_captain_command(uuid,varchar,varchar,varchar,text,jsonb,jsonb,text,text,varchar) from public, anon, authenticated;
revoke all on function public.get_squad_session_projection(uuid) from public, anon, authenticated;
grant execute on function public.submit_captain_command(uuid,varchar,varchar,varchar,text,jsonb,jsonb,text,text,varchar) to authenticated;
grant execute on function public.get_squad_session_projection(uuid) to authenticated;
