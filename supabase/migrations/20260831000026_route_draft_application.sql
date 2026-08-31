-- Route draft application fixes: persist an autonomous title and support empty route trips.
-- This migration follows 20260829000021_agent_captain_commands.sql.

alter table public.trip_drafts
  add column if not exists proposed_title varchar(80);

alter table public.trip_drafts
  drop constraint if exists trip_drafts_proposed_title_ck;
alter table public.trip_drafts
  add constraint trip_drafts_proposed_title_ck check (
    proposed_title is null or char_length(btrim(proposed_title)) between 1 and 80
  );

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
  draft_item jsonb;
  draft_day date;
  planned_start timestamptz;
  planned_end timestamptz;
  draft_title text;
  next_position integer;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_idempotency_key is null or p_expected_revision is null then
    raise exception using errcode = '22023', message = 'revision and idempotency key are required';
  end if;

  request_hash := digest(jsonb_build_object(
    'draftId', p_draft_id,
    'expectedRevision', p_expected_revision
  )::text, 'sha256');
  prior := public.agent_idempotency_begin_result(
    actor, 'apply_trip_draft', p_idempotency_key, request_hash
  );
  if prior is not null then
    return jsonb_build_object(
      'alreadyApplied', true,
      'tripId', prior->>'tripId',
      'revision', (prior->>'revision')::bigint,
      'itemsCreated', (prior->>'itemsCreated')::integer
    );
  end if;

  select * into draft
  from public.trip_drafts d
  where d.id = p_draft_id
    and exists (
      select 1 from public.trips t
      where t.id = d.trip_id and t.user_id = actor
    )
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip draft not found';
  end if;
  if draft.status in ('applied', 'rejected', 'expired') then
    raise exception using errcode = '22023', message = 'trip draft already resolved';
  end if;

  select * into trip_row
  from public.trips
  where id = draft.trip_id and user_id = actor
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'trip not found';
  end if;
  if trip_row.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'trip revision conflict';
  end if;
  if draft.base_revision <> p_expected_revision then
    update public.trip_drafts set status = 'conflicted', updated_at = now()
    where id = p_draft_id;
    raise exception using errcode = '40001', message = 'trip draft revision conflict';
  end if;
  perform public.assert_trip_writable(draft.trip_id);

  draft_title := nullif(btrim(draft.proposed_title), '');
  if draft_title is not null and char_length(draft_title) > 80 then
    raise exception using errcode = '22023', message = 'draft title is too long';
  end if;
  if draft_title is not null then
    update public.trips set title = draft_title where id = draft.trip_id;
  end if;

  -- Dates are derived from the inserted nodes; fresh route trips intentionally have
  -- null start_date/end_date before their first draft is applied.
  for draft_item in select * from jsonb_array_elements(draft.items) loop
    draft_day := nullif(draft_item->>'localDate', '')::date;
    planned_start := nullif(draft_item->>'plannedStartAt', '')::timestamptz;
    planned_end := nullif(draft_item->>'plannedEndAt', '')::timestamptz;
    if draft_day is null or planned_start is null or planned_end is null then
      raise exception using errcode = '22023', message = 'draft item has incomplete schedule';
    end if;
    if planned_end <= planned_start then
      raise exception using errcode = '22023', message = 'draft item has invalid schedule';
    end if;
    if (planned_start at time zone trip_row.timezone)::date <> draft_day then
      raise exception using errcode = '23514', message = 'draft item date does not match start time';
    end if;
    if not public.trip_date_allowed(trip_row.timezone, draft_day) then
      raise exception using errcode = '22023', message = 'draft item date is outside the supported range';
    end if;

    insert into public.trip_days(trip_id, local_date)
    values (draft.trip_id, draft_day)
    on conflict (trip_id, local_date) do nothing;
    select id into day_id
    from public.trip_days
    where trip_id = draft.trip_id and local_date = draft_day;

    select coalesce(max(position) + 1, 0) into next_position
    from public.trip_items
    where trip_day_id = day_id;

    insert into public.trip_items(
      trip_id, trip_day_id, item_type, place_id, title,
      planned_start_at, planned_end_at, time_slot, position,
      estimated_cost_min_minor, estimated_cost_max_minor,
      created_by, source_agent_task_id, place_snapshot
    ) values (
      draft.trip_id,
      day_id,
      coalesce(nullif(draft_item->>'itemType', ''), 'place_visit'),
      nullif(draft_item->>'placeId', '')::uuid,
      coalesce(nullif(btrim(draft_item->>'title'), ''), '美食到访'),
      planned_start,
      planned_end,
      coalesce(nullif(draft_item->>'timeSlot', ''), 'flexible'),
      next_position,
      nullif(draft_item->>'estimatedCostMinMinor', '')::bigint,
      nullif(draft_item->>'estimatedCostMaxMinor', '')::bigint,
      'agent', draft.source_task_id, draft_item->'placeSnapshot'
    ) returning * into item_row;
    created_count := created_count + 1;
  end loop;

  perform public.sync_trip_calendar(draft.trip_id);
  update public.trips set revision = revision + 1
  where id = draft.trip_id
  returning revision into new_revision;
  update public.trip_drafts set status = 'applied', updated_at = now()
  where id = p_draft_id;

  perform public.agent_idempotency_store_result(
    actor,
    p_idempotency_key,
    jsonb_build_object(
      'tripId', draft.trip_id,
      'revision', new_revision,
      'itemsCreated', created_count
    )
  );
  perform public.append_squad_event(
    draft.session_id, null, draft.source_task_id, 'trip.updated', 'orchestrator',
    jsonb_build_object(
      'tripId', draft.trip_id,
      'draftId', p_draft_id,
      'revision', new_revision,
      'itemsCreated', created_count,
      'title', draft_title
    )
  );
  return jsonb_build_object(
    'tripId', draft.trip_id,
    'revision', new_revision,
    'itemsCreated', created_count
  );
end;
$$;

revoke all on function public.apply_trip_draft(uuid, bigint, uuid)
from public, anon, authenticated;
grant execute on function public.apply_trip_draft(uuid, bigint, uuid) to authenticated;
