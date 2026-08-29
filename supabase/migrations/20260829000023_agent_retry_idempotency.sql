-- Prevent a retried orchestration from producing duplicate captain-visible
-- proposals for the same session.
create unique index if not exists memory_proposals_session_key_uq
  on public.memory_proposals(session_id, memory_key);

create unique index if not exists recommendation_sets_session_active_uq
  on public.recommendation_sets(session_id)
  where status in ('draft', 'generated', 'displayed', 'captain_selected');
