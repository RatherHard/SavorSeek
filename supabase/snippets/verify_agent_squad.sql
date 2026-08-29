-- Run after `supabase db reset` or against an isolated Supabase-compatible database.
-- Every query should return the expected count/value shown in its comment.

select count(*) as agent_table_count
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'squad_sessions', 'captain_commands', 'agent_plans', 'agent_tasks',
    'agent_steps', 'agent_artifacts', 'squad_events',
    'decision_checkpoints', 'memory_proposals', 'recommendation_sets',
    'trip_drafts', 'agent_command_idempotency_keys', 'user_memories',
    'recommendation_feedbacks'
  ); -- expected: 14

select count(*) as rls_table_count
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'squad_sessions', 'captain_commands', 'agent_plans', 'agent_tasks',
    'agent_steps', 'agent_artifacts', 'squad_events',
    'decision_checkpoints', 'memory_proposals', 'recommendation_sets',
    'trip_drafts', 'agent_command_idempotency_keys', 'user_memories',
    'recommendation_feedbacks'
  )
  and c.relrowsecurity; -- expected: 14

select count(*) as captain_rpc_count
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('submit_captain_command', 'get_squad_session_projection',
    'cancel_squad_session', 'list_squad_events', 'retry_agent_task',
    'select_recommendation', 'reject_recommendation',
    'submit_recommendation_feedback', 'resolve_memory_proposal',
    'resolve_decision_checkpoint', 'apply_trip_draft'); -- expected: 11

select count(*) as realtime_table_count
from pg_publication p
join pg_publication_rel pr on pr.prpubid = p.oid
join pg_class c on c.oid = pr.prrelid
join pg_namespace n on n.oid = c.relnamespace
where p.pubname = 'supabase_realtime'
  and n.nspname = 'public'
  and c.relname in (
    'squad_sessions', 'captain_commands', 'agent_tasks', 'agent_artifacts',
    'squad_events', 'decision_checkpoints', 'memory_proposals',
    'recommendation_sets', 'trip_drafts'
  ); -- expected: 9

select count(*) as command_rpc_count
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'submit_captain_command', 'cancel_squad_session', 'list_squad_events',
    'append_squad_event', 'agent_idempotency_begin', 'agent_idempotency_store'
  ); -- expected: 6

select
  has_function_privilege('authenticated', 'public.submit_captain_command(uuid,varchar,varchar,varchar,text,jsonb,jsonb,text,text,varchar)', 'EXECUTE')
    as submit_rpc_granted,
  has_function_privilege('authenticated', 'public.cancel_squad_session(uuid)', 'EXECUTE')
    as cancel_rpc_granted,
  has_function_privilege('authenticated', 'public.list_squad_events(uuid,bigint,integer)', 'EXECUTE')
    as list_events_rpc_granted; -- expected: true, true, true
