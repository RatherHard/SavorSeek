-- Agent squad persistence model.
-- Client writes are exposed through narrow RPCs in the companion migration.

create table if not exists public.squad_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title varchar(120) not null,
  goal varchar(2000) not null,
  status text not null default 'idle',
  active_command_id uuid,
  map_context jsonb not null default '{}'::jsonb,
  trip_context jsonb not null default '{}'::jsonb,
  selected_place_ids uuid[] not null default '{}'::uuid[],
  projection_version bigint not null default 1,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint squad_sessions_title_ck check (char_length(btrim(title)) between 1 and 120),
  constraint squad_sessions_goal_ck check (char_length(btrim(goal)) between 1 and 2000),
  constraint squad_sessions_status_ck check (status in ('idle','receiving_command','interpreting','dispatching','working','awaiting_captain_decision','applying_decision','completed','partially_completed','timed_out','failed','cancelled')),
  constraint squad_sessions_projection_ck check (projection_version >= 1),
  constraint squad_sessions_map_context_ck check (jsonb_typeof(map_context) = 'object'),
  constraint squad_sessions_trip_context_ck check (jsonb_typeof(trip_context) = 'object')
);

create unique index if not exists squad_sessions_id_user_uq on public.squad_sessions(id, user_id);

create table if not exists public.captain_commands (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  client_request_id uuid not null,
  schema_version integer not null default 1,
  raw_text varchar(2000) not null,
  task_type text not null,
  context jsonb not null default '{}'::jsonb,
  constraints_json jsonb not null default '{}'::jsonb,
  memory_policy text not null default 'propose_only',
  locale text not null default 'zh-CN',
  client_version varchar(64),
  status text not null default 'accepted',
  created_at timestamptz not null default now(),
  constraint captain_commands_session_user_fk foreign key (session_id, user_id) references public.squad_sessions(id, user_id) on delete cascade,
  constraint captain_commands_client_request_uq unique (user_id, client_request_id),
  constraint captain_commands_schema_ck check (schema_version >= 1),
  constraint captain_commands_text_ck check (char_length(btrim(raw_text)) between 1 and 2000),
  constraint captain_commands_task_type_ck check (task_type in ('discover_places','compare_recommendations','plan_route','replan_trip','general_exploration')),
  constraint captain_commands_memory_policy_ck check (memory_policy in ('disabled','read_only','propose_only')),
  constraint captain_commands_status_ck check (status in ('accepted','processing','completed','partially_completed','failed','cancelled')),
  constraint captain_commands_context_ck check (jsonb_typeof(context) = 'object'),
  constraint captain_commands_constraints_ck check (jsonb_typeof(constraints_json) = 'object')
);

create unique index if not exists captain_commands_id_session_uq on public.captain_commands(id, session_id);


alter table public.squad_sessions
  add constraint squad_sessions_active_command_fk
  foreign key (active_command_id) references public.captain_commands(id) on delete set null;

create table if not exists public.agent_plans (
  id uuid primary key default gen_random_uuid(),
  command_id uuid not null references public.captain_commands(id) on delete cascade,
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  orchestration_version integer not null default 1,
  dependency_graph jsonb not null default '{}'::jsonb,
  max_duration_ms integer not null default 120000,
  max_cost_minor bigint,
  status text not null default 'queued',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agent_plans_command_session_fk foreign key (command_id, session_id) references public.captain_commands(id, session_id) on delete cascade,
  constraint agent_plans_version_ck check (orchestration_version >= 1),
  constraint agent_plans_duration_ck check (max_duration_ms between 1000 and 3600000),
  constraint agent_plans_cost_ck check (max_cost_minor is null or max_cost_minor >= 0),
  constraint agent_plans_status_ck check (status in ('queued','running','awaiting_captain_decision','succeeded','partial','failed','timed_out','cancelled')),
  constraint agent_plans_graph_ck check (jsonb_typeof(dependency_graph) = 'object')
);

create unique index if not exists agent_plans_id_session_uq on public.agent_plans(id, session_id);

create table if not exists public.agent_tasks (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.agent_plans(id) on delete cascade,
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  command_id uuid not null references public.captain_commands(id) on delete cascade,
  role text not null,
  parent_task_id uuid references public.agent_tasks(id) on delete set null,
  status text not null default 'queued',
  progress smallint not null default 0,
  input_artifact_ids uuid[] not null default '{}'::uuid[],
  output_artifact_ids uuid[] not null default '{}'::uuid[],
  user_summary varchar(2000),
  error_code text,
  retry_count smallint not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agent_tasks_plan_session_fk foreign key (plan_id, session_id) references public.agent_plans(id, session_id) on delete cascade,
  constraint agent_tasks_command_session_fk foreign key (command_id, session_id) references public.captain_commands(id, session_id) on delete cascade,
  constraint agent_tasks_role_ck check (role in ('result_coordinator','intent_interpreter','map_explorer','preference_advisor','content_researcher','fact_checker','recommendation_decider','route_planner')),
  constraint agent_tasks_status_ck check (status in ('queued','assigned','running','waiting_for_dependency','waiting_for_captain','succeeded','partial','retrying','timed_out','failed','cancelled')),
  constraint agent_tasks_progress_ck check (progress between 0 and 100),
  constraint agent_tasks_retry_ck check (retry_count >= 0),
  constraint agent_tasks_version_ck check (version >= 1)
);

create unique index if not exists agent_plans_id_command_uq on public.agent_plans(id, command_id);
create unique index if not exists agent_tasks_id_plan_uq on public.agent_tasks(id, plan_id);
create unique index if not exists agent_tasks_id_session_uq on public.agent_tasks(id, session_id);


create table if not exists public.agent_artifacts (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  task_id uuid not null references public.agent_tasks(id) on delete cascade,
  schema_version integer not null default 1,
  artifact_type text not null,
  producer text not null,
  input_artifact_ids uuid[] not null default '{}'::uuid[],
  payload jsonb not null default '{}'::jsonb,
  source_refs uuid[] not null default '{}'::uuid[],
  confidence numeric(5,4),
  warnings jsonb not null default '[]'::jsonb,
  freshness jsonb,
  requires_captain_approval boolean not null default false,
  is_captain_visible boolean not null default true,
  created_at timestamptz not null default now(),
  constraint agent_artifacts_task_session_fk foreign key (task_id, session_id) references public.agent_tasks(id, session_id) on delete cascade,
  constraint agent_artifacts_schema_ck check (schema_version >= 1),
  constraint agent_artifacts_confidence_ck check (confidence is null or confidence between 0 and 1),
  constraint agent_artifacts_payload_ck check (jsonb_typeof(payload) = 'object'),
  constraint agent_artifacts_warnings_ck check (jsonb_typeof(warnings) = 'array'),
  constraint agent_artifacts_freshness_ck check (freshness is null or jsonb_typeof(freshness) = 'object')
);

create table if not exists public.agent_steps (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.agent_tasks(id) on delete cascade,
  plan_id uuid not null references public.agent_plans(id) on delete cascade,
  kind text not null,
  depends_on uuid[] not null default '{}'::uuid[],
  status text not null default 'queued',
  input_artifact_ids uuid[] not null default '{}'::uuid[],
  output_artifact_ids uuid[] not null default '{}'::uuid[],
  tool_name text,
  attempt smallint not null default 0,
  lease_expires_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  error_code text,
  created_at timestamptz not null default now(),
  constraint agent_steps_task_plan_fk foreign key (task_id, plan_id) references public.agent_tasks(id, plan_id) on delete cascade,
  constraint agent_steps_status_ck check (status in ('queued','running','waiting_for_dependency','waiting_for_captain','succeeded','partial','retrying','timed_out','failed','cancelled')),
  constraint agent_steps_attempt_ck check (attempt >= 0)
);

create table if not exists public.squad_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  command_id uuid references public.captain_commands(id) on delete set null,
  task_id uuid references public.agent_tasks(id) on delete set null,
  sequence bigint not null,
  schema_version integer not null default 1,
  event_type text not null,
  occurred_at timestamptz not null default now(),
  actor text not null,
  visibility text not null default 'captain',
  payload jsonb not null default '{}'::jsonb,
  constraint squad_events_session_sequence_uq unique (session_id, sequence),
  constraint squad_events_actor_ck check (actor in ('captain','agent','orchestrator','system','external_source')),
  constraint squad_events_visibility_ck check (visibility in ('captain','internal')),
  constraint squad_events_payload_ck check (jsonb_typeof(payload) = 'object'),
  constraint squad_events_schema_ck check (schema_version >= 1)
);

create table if not exists public.decision_checkpoints (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  task_id uuid references public.agent_tasks(id) on delete set null,
  kind text not null,
  question varchar(2000) not null,
  options jsonb not null,
  affected_resource_refs jsonb not null default '[]'::jsonb,
  expires_at timestamptz,
  status text not null default 'pending',
  selected_option_id text,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint decision_checkpoints_question_ck check (char_length(btrim(question)) between 1 and 2000),
  constraint decision_checkpoints_options_ck check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) > 0),
  constraint decision_checkpoints_refs_ck check (jsonb_typeof(affected_resource_refs) = 'array'),
  constraint decision_checkpoints_status_ck check (status in ('pending','accepted','rejected','expired','cancelled'))
);

create table if not exists public.memory_proposals (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  task_id uuid references public.agent_tasks(id) on delete set null,
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  memory_key varchar(120) not null,
  proposed_value jsonb not null,
  evidence_refs uuid[] not null default '{}'::uuid[],
  confidence numeric(5,4),
  status text not null default 'proposed',
  captain_value jsonb,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint memory_proposals_session_user_fk foreign key (session_id, user_id) references public.squad_sessions(id, user_id) on delete cascade,
  constraint memory_proposals_operation_ck check (operation in ('create','update','delete')),
  constraint memory_proposals_key_ck check (char_length(btrim(memory_key)) between 1 and 120),
  constraint memory_proposals_confidence_ck check (confidence is null or confidence between 0 and 1),
  constraint memory_proposals_status_ck check (status in ('proposed','shown_to_captain','accepted','rejected','edited','expired'))
);

create table if not exists public.recommendation_sets (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  task_id uuid not null references public.agent_tasks(id) on delete cascade,
  artifact_id uuid references public.agent_artifacts(id) on delete set null,
  status text not null default 'generated',
  items jsonb not null default '[]'::jsonb,
  selected_place_ids uuid[] not null default '{}'::uuid[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recommendation_sets_items_ck check (jsonb_typeof(items) = 'array'),
  constraint recommendation_sets_status_ck check (status in ('draft','generated','displayed','captain_selected','rejected','expired','added_to_trip'))
);

create table if not exists public.trip_drafts (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  session_id uuid not null references public.squad_sessions(id) on delete cascade,
  source_task_id uuid references public.agent_tasks(id) on delete set null,
  base_revision bigint not null,
  status text not null default 'proposed',
  items jsonb not null default '[]'::jsonb,
  route_segments jsonb not null default '[]'::jsonb,
  conflicts jsonb not null default '[]'::jsonb,
  budget_summary jsonb not null default '{}'::jsonb,
  duration_summary jsonb not null default '{}'::jsonb,
  locked_fields jsonb not null default '[]'::jsonb,
  source_refs uuid[] not null default '{}'::uuid[],
  warnings jsonb not null default '[]'::jsonb,
  requires_captain_approval boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trip_drafts_base_revision_ck check (base_revision >= 1),
  constraint trip_drafts_status_ck check (status in ('proposed','shown_to_captain','accepted','rejected','applied','expired','conflicted')),
  constraint trip_drafts_items_ck check (jsonb_typeof(items) = 'array'),
  constraint trip_drafts_route_ck check (jsonb_typeof(route_segments) = 'array'),
  constraint trip_drafts_conflicts_ck check (jsonb_typeof(conflicts) = 'array')
);

create table if not exists public.agent_command_idempotency_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  client_request_id uuid not null,
  request_hash bytea not null,
  command_id uuid references public.captain_commands(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, client_request_id)
);

create index if not exists squad_sessions_user_updated_idx on public.squad_sessions(user_id, updated_at desc);
create index if not exists captain_commands_session_created_idx on public.captain_commands(session_id, created_at desc);
create index if not exists agent_tasks_session_status_idx on public.agent_tasks(session_id, status, updated_at desc);
create index if not exists agent_steps_task_status_idx on public.agent_steps(task_id, status);
create index if not exists agent_artifacts_session_created_idx on public.agent_artifacts(session_id, created_at desc);
create index if not exists squad_events_session_sequence_idx on public.squad_events(session_id, sequence desc);
create index if not exists decision_checkpoints_session_status_idx on public.decision_checkpoints(session_id, status);
create index if not exists memory_proposals_user_status_idx on public.memory_proposals(user_id, status, created_at desc);
create index if not exists recommendation_sets_session_created_idx on public.recommendation_sets(session_id, created_at desc);
create index if not exists trip_drafts_trip_created_idx on public.trip_drafts(trip_id, created_at desc);

create or replace function public.touch_agent_updated_at()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger squad_sessions_updated_at before update on public.squad_sessions for each row execute function public.touch_agent_updated_at();
create trigger agent_plans_updated_at before update on public.agent_plans for each row execute function public.touch_agent_updated_at();
create trigger agent_tasks_updated_at before update on public.agent_tasks for each row execute function public.touch_agent_updated_at();
create trigger recommendation_sets_updated_at before update on public.recommendation_sets for each row execute function public.touch_agent_updated_at();
create trigger trip_drafts_updated_at before update on public.trip_drafts for each row execute function public.touch_agent_updated_at();

alter table public.squad_sessions enable row level security;
alter table public.captain_commands enable row level security;
alter table public.agent_plans enable row level security;
alter table public.agent_tasks enable row level security;
alter table public.agent_steps enable row level security;
alter table public.agent_artifacts enable row level security;
alter table public.squad_events enable row level security;
alter table public.decision_checkpoints enable row level security;
alter table public.memory_proposals enable row level security;
alter table public.recommendation_sets enable row level security;
alter table public.trip_drafts enable row level security;
alter table public.agent_command_idempotency_keys enable row level security;

create policy squad_sessions_select_own on public.squad_sessions for select to authenticated using (user_id = auth.uid());
create policy captain_commands_select_own on public.captain_commands for select to authenticated using (user_id = auth.uid());
create policy agent_plans_select_own on public.agent_plans for select to authenticated using (exists (select 1 from public.squad_sessions s where s.id = agent_plans.session_id and s.user_id = auth.uid()));
create policy agent_tasks_select_own on public.agent_tasks for select to authenticated using (exists (select 1 from public.squad_sessions s where s.id = agent_tasks.session_id and s.user_id = auth.uid()));
create policy agent_steps_select_own on public.agent_steps for select to authenticated using (exists (select 1 from public.agent_tasks t join public.squad_sessions s on s.id = t.session_id where t.id = agent_steps.task_id and s.user_id = auth.uid()));
create policy agent_artifacts_select_own on public.agent_artifacts for select to authenticated using (exists (select 1 from public.squad_sessions s where s.id = agent_artifacts.session_id and s.user_id = auth.uid()) and is_captain_visible);
create policy squad_events_select_own on public.squad_events for select to authenticated using (visibility = 'captain' and exists (select 1 from public.squad_sessions s where s.id = squad_events.session_id and s.user_id = auth.uid()));
create policy decision_checkpoints_select_own on public.decision_checkpoints for select to authenticated using (exists (select 1 from public.squad_sessions s where s.id = decision_checkpoints.session_id and s.user_id = auth.uid()));
create policy memory_proposals_select_own on public.memory_proposals for select to authenticated using (user_id = auth.uid());
create policy recommendation_sets_select_own on public.recommendation_sets for select to authenticated using (exists (select 1 from public.squad_sessions s where s.id = recommendation_sets.session_id and s.user_id = auth.uid()));
create policy trip_drafts_select_own on public.trip_drafts for select to authenticated using (exists (select 1 from public.trips t where t.id = trip_drafts.trip_id and t.user_id = auth.uid()));

revoke all on public.squad_sessions, public.captain_commands, public.agent_plans, public.agent_tasks, public.agent_steps, public.agent_artifacts, public.squad_events, public.decision_checkpoints, public.memory_proposals, public.recommendation_sets, public.trip_drafts, public.agent_command_idempotency_keys from anon, authenticated;
grant select on public.squad_sessions, public.captain_commands, public.agent_plans, public.agent_tasks, public.agent_steps, public.agent_artifacts, public.squad_events, public.decision_checkpoints, public.memory_proposals, public.recommendation_sets, public.trip_drafts to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.squad_sessions;
  alter publication supabase_realtime add table public.captain_commands;
  alter publication supabase_realtime add table public.agent_tasks;
  alter publication supabase_realtime add table public.agent_artifacts;
  alter publication supabase_realtime add table public.squad_events;
  alter publication supabase_realtime add table public.decision_checkpoints;
  alter publication supabase_realtime add table public.memory_proposals;
  alter publication supabase_realtime add table public.recommendation_sets;
  alter publication supabase_realtime add table public.trip_drafts;
exception when duplicate_object then null;
end;
$$;

revoke all on function public.touch_agent_updated_at() from public, anon, authenticated;
