-- Validate edited memory values at the trusted RPC boundary.
-- Client-side validation remains a UX improvement, not the data-integrity boundary.

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
  if p_decision = 'edit' and proposal.operation = 'delete' then
    raise exception using errcode = '22023', message = 'delete memory proposal cannot be edited';
  end if;
  if p_decision = 'edit' and proposal.memory_key not in ('avoid', 'budget_per_person') then
    raise exception using errcode = '22023', message = 'memory type cannot be edited';
  end if;
  if p_decision = 'edit' and proposal.memory_key = 'avoid' then
    if jsonb_typeof(p_edited_value->'items') <> 'array' then
      raise exception using errcode = '22023', message = 'invalid avoid memory value';
    end if;
    if jsonb_array_length(p_edited_value->'items') not between 1 and 20 then
      raise exception using errcode = '22023', message = 'invalid avoid memory value';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(p_edited_value->'items') item
      where jsonb_typeof(item) <> 'string'
        or char_length(btrim(item #>> '{}')) not between 1 and 40
    ) then
      raise exception using errcode = '22023', message = 'invalid avoid memory value';
    end if;
  end if;
  if p_decision = 'edit' and proposal.memory_key = 'budget_per_person' then
    if jsonb_typeof(p_edited_value->'maxMinor') <> 'number' then
      raise exception using errcode = '22023', message = 'invalid budget memory value';
    end if;
    if (p_edited_value->>'maxMinor') !~ '^[0-9]+$' then
      raise exception using errcode = '22023', message = 'invalid budget memory value';
    end if;
    if (p_edited_value->>'maxMinor')::numeric not between 1 and 100000000 then
      raise exception using errcode = '22023', message = 'invalid budget memory value';
    end if;
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
  return jsonb_build_object(
    'proposalId', p_proposal_id,
    'status', case p_decision when 'accept' then 'accepted' when 'edit' then 'edited' else 'rejected' end
  );
end;
$$;

revoke all on function public.resolve_memory_proposal(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.resolve_memory_proposal(uuid, text, jsonb)
  to authenticated;
