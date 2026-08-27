-- User-owned place favorites.
--
-- Favorites are private relations. Direct table DML is intentionally revoked from
-- client roles; the authenticated RPCs below derive ownership from auth.uid().
-- place_id cascades only when public place data is administratively cleaned up
-- (for example a duplicate merge, provider removal, or compliance deletion). It
-- does not expose a user-facing delete-place operation.

create table if not exists public.favorites (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  place_id uuid not null references public.places(id) on delete cascade,
  note varchar(500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint favorites_user_place_uq unique (user_id, place_id),
  constraint favorites_note_ck check (
    note is null or char_length(btrim(note)) between 1 and 500
  )
);

create index if not exists favorites_user_created_idx
  on public.favorites (user_id, created_at desc);

create table if not exists public.favorite_idempotency_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  operation text not null,
  request_hash bytea not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (user_id, idempotency_key),
  constraint favorite_idempotency_operation_ck
    check (operation in ('add_favorite', 'remove_favorite'))
);

alter table public.favorites enable row level security;
alter table public.favorite_idempotency_keys enable row level security;

create policy favorites_select_own on public.favorites
  for select to authenticated using (user_id = auth.uid());
create policy favorites_insert_own on public.favorites
  for insert to authenticated
  with check (user_id = auth.uid());
create policy favorites_update_own on public.favorites
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy favorites_delete_own on public.favorites
  for delete to authenticated using (user_id = auth.uid());

revoke all on public.favorites, public.favorite_idempotency_keys
  from anon, authenticated;

create or replace function public.favorite_idempotency_begin(
  p_user_id uuid,
  p_operation text,
  p_idempotency_key uuid,
  p_request_hash bytea
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  existing public.favorite_idempotency_keys%rowtype;
begin
  if p_idempotency_key is null then
    raise exception using errcode = '22023', message = 'idempotency key is required';
  end if;
  insert into public.favorite_idempotency_keys(
    user_id, idempotency_key, operation, request_hash
  ) values (p_user_id, p_idempotency_key, p_operation, p_request_hash)
  on conflict (user_id, idempotency_key) do nothing;

  select * into existing
  from public.favorite_idempotency_keys
  where user_id = p_user_id and idempotency_key = p_idempotency_key
  for update;

  if existing.operation <> p_operation or existing.request_hash <> p_request_hash then
    raise exception using
      errcode = '22023', message = 'idempotency key was reused with different request data';
  end if;
  return existing.result;
end;
$$;

create or replace function public.favorite_idempotency_store(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_result jsonb
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.favorite_idempotency_keys
  set result = p_result
  where user_id = p_user_id and idempotency_key = p_idempotency_key;
$$;

create or replace function public.add_favorite(
  p_place_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := auth.uid();
  prior jsonb;
  favorite_id uuid;
  result jsonb;
  request_hash bytea;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(
    jsonb_build_object(
      'operation', 'add_favorite', 'place_id', p_place_id
    )::text, 'sha256'
  );
  prior := public.favorite_idempotency_begin(
    actor, 'add_favorite', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  if not exists (select 1 from public.places where id = p_place_id) then
    raise exception using errcode = '22023', message = 'place not found';
  end if;

  insert into public.favorites(user_id, place_id)
  values (actor, p_place_id)
  on conflict (user_id, place_id) do nothing
  returning id into favorite_id;

  if favorite_id is null then
    select id into favorite_id
    from public.favorites
    where user_id = actor and place_id = p_place_id;
  end if;
  result := jsonb_build_object(
    'favorite_id', favorite_id,
    'place_id', p_place_id,
    'is_favorite', true
  );
  perform public.favorite_idempotency_store(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.remove_favorite(
  p_place_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  actor uuid := auth.uid();
  prior jsonb;
  result jsonb;
  request_hash bytea;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  request_hash := digest(
    jsonb_build_object(
      'operation', 'remove_favorite', 'place_id', p_place_id
    )::text, 'sha256'
  );
  prior := public.favorite_idempotency_begin(
    actor, 'remove_favorite', p_idempotency_key, request_hash
  );
  if prior is not null then return prior; end if;

  delete from public.favorites
  where user_id = actor and place_id = p_place_id;
  result := jsonb_build_object(
    'place_id', p_place_id,
    'is_favorite', false
  );
  perform public.favorite_idempotency_store(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.get_favorite_statuses(p_place_ids uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare actor uuid := auth.uid();
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_place_ids is null or cardinality(p_place_ids) > 100 then
    raise exception using errcode = '22023', message = 'place id batch is limited to 100';
  end if;
  return coalesce(
    (select array_agg(place_id order by place_id)
     from public.favorites
     where user_id = actor
       and (
         cardinality(p_place_ids) = 0
         or place_id = any(p_place_ids)
       )),
    '{}'::uuid[]
  );
end;
$$;

create or replace function public.list_favorites(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  items jsonb;
  item_count integer;
begin
  if actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100
     or p_offset is null or p_offset < 0 or p_offset > 10000 then
    raise exception using errcode = '22023', message = 'invalid favorites pagination';
  end if;

  select count(*)::integer into item_count
  from public.favorites f
  where f.user_id = actor;

  select coalesce(jsonb_agg(jsonb_build_object(
    'favorite_id', page.id,
    'place_id', page.place_id,
    'name', page.name,
    'category', page.category,
    'address', page.address,
    'latitude', page.latitude,
    'longitude', page.longitude,
    'fetched_at', page.fetched_at,
    'created_at', page.created_at
  ) order by page.created_at desc, page.id), '[]'::jsonb)
  into items
  from (
    select
      f.id,
      f.created_at,
      p.id as place_id,
      p.name,
      p.category,
      p.address,
      p.latitude,
      p.longitude,
      p.fetched_at
    from public.favorites f
    join public.places p on p.id = f.place_id
    where f.user_id = actor
    order by f.created_at desc, f.id
    offset p_offset limit p_limit
  ) as page;

  return jsonb_build_object(
    'items', items,
    'has_more', (p_offset::bigint + p_limit::bigint) < item_count
  );
end;
$$;

revoke all on function public.favorite_idempotency_begin(uuid,text,uuid,bytea)
  from public, anon, authenticated;
revoke all on function public.favorite_idempotency_store(uuid,uuid,jsonb)
  from public, anon, authenticated;
revoke all on function public.add_favorite(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.remove_favorite(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.get_favorite_statuses(uuid[])
  from public, anon, authenticated;
revoke all on function public.list_favorites(integer,integer)
  from public, anon, authenticated;

grant execute on function public.add_favorite(uuid,uuid) to authenticated;
grant execute on function public.remove_favorite(uuid,uuid) to authenticated;
grant execute on function public.get_favorite_statuses(uuid[]) to authenticated;
grant execute on function public.list_favorites(integer,integer) to authenticated;
