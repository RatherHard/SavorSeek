-- Extend the captain-facing session projection with memory proposals.
-- Keep the previously deployed projection migration immutable.

create or replace function public.get_squad_session_projection(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare actor uuid := auth.uid(); result jsonb;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  select jsonb_build_object(
    'session', to_jsonb(s),
    'commands', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.captain_commands c where c.session_id=s.id), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at) from public.agent_plans p where p.session_id=s.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.agent_tasks t where t.session_id=s.id), '[]'::jsonb),
    'artifacts', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.agent_artifacts a where a.session_id=s.id and a.is_captain_visible), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.sequence) from public.squad_events e where e.session_id=s.id and e.visibility='captain'), '[]'::jsonb),
    'decisions', coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at) from public.decision_checkpoints d where d.session_id=s.id), '[]'::jsonb),
    'recommendations', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.recommendation_sets r where r.session_id=s.id), '[]'::jsonb),
    'drafts', coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at) from public.trip_drafts d where d.session_id=s.id), '[]'::jsonb),
    'memory_proposals', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from public.memory_proposals m where m.session_id=s.id and m.user_id=actor), '[]'::jsonb)
  ) into result
  from public.squad_sessions s
  where s.id=p_session_id and s.user_id=actor;

  if result is null then
    raise exception using errcode = '42501', message = 'session not found';
  end if;
  return result;
end;
$$;

revoke all on function public.get_squad_session_projection(uuid) from public, anon, authenticated;
grant execute on function public.get_squad_session_projection(uuid) to authenticated;
