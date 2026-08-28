-- Run after `supabase db reset` or against an isolated Supabase-compatible database.
-- Every query should return the expected count/value shown in its comment.

select count(*) as agent_table_count
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'squad_sessions', 'captain_commands', 'agent_plans', 'agent_tasks',
    'agent_steps', 'agent_artifacts', 'squad_events',
    'decision_checkpoints', 'memory_proposals', 'recommendation_sets',
    'trip_drafts', 'agent_command_idempotency_keys'
  ); -- expected: 12

select count(*) as rls_table_count
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'squad_sessions', 'captain_commands', 'agent_plans', 'agent_tasks',
    'agent_steps', 'agent_artifacts', 'squad_events',
    'decision_checkpoints', 'memory_proposals', 'recommendation_sets',
    'trip_drafts', 'agent_command_idempotency_keys'
  )
  and c.relrowsecurity; -- expected: 12

select count(*) as captain_rpc_count
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('submit_captain_command', 'get_squad_session_projection'); -- expected: 2

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
