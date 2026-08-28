-- AMap POI rating propagated as a typed, nullable scalar.
-- This forward migration intentionally leaves prior migrations unchanged.

alter table public.places
  add column if not exists rating numeric(2, 1);

alter table public.places
  drop constraint if exists places_rating_ck;

alter table public.places
  add constraint places_rating_ck check (
    rating is null or (rating >= 0 and rating <= 5)
  );

create or replace function public.place_public_json(p public.places)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'category', p.category,
    'address', p.address,
    'latitude', p.latitude,
    'longitude', p.longitude,
    'rating', p.rating,
    'fetched_at', p.fetched_at
  );
$$;

create or replace function public.lookup_place_search(
  p_search_kind text,
  p_query_params jsonb,
  p_ttl_seconds integer default 86400
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  cached public.place_searches%rowtype;
  places_json jsonb;
begin
  if p_ttl_seconds is null or p_ttl_seconds < 0 then
    raise exception using errcode = '22023', message = 'ttl_seconds must be a non-negative integer';
  end if;

  select * into cached
  from public.place_searches
  where provider = 'amap'
    and search_kind = p_search_kind
    and query_hash = public.place_search_query_hash(p_query_params);
  if not found then
    return null;
  end if;
  if cached.fetched_at < now() - make_interval(secs => p_ttl_seconds) then
    return null;
  end if;

  select coalesce(
    jsonb_agg(public.place_public_json(p) order by ordered.ordinality),
    '[]'::jsonb
  )
  into places_json
  from unnest(cached.place_ids) with ordinality as ordered(place_id, ordinality)
  join public.places p on p.id = ordered.place_id;

  return jsonb_build_object(
    'fetched_at', cached.fetched_at,
    'from_cache', true,
    'places', places_json
  );
end;
$$;

create or replace function public.upsert_amap_places(
  p_search_kind text,
  p_query_params jsonb,
  p_places jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  ordered_ids uuid[];
  now_ts timestamptz := now();
  places_json jsonb;
begin
  if p_search_kind not in ('text', 'around') then
    raise exception using errcode = '22023', message = 'search_kind must be text or around';
  end if;
  if p_places is null or jsonb_typeof(p_places) <> 'array' then
    raise exception using errcode = '22023', message = 'places must be a json array';
  end if;
  if p_query_params is null or jsonb_typeof(p_query_params) <> 'object' then
    raise exception using errcode = '22023', message = 'query_params must be a json object';
  end if;

  with incoming as (
    select
      ordinality,
      btrim(item ->> 'provider_place_id') as provider_place_id,
      btrim(item ->> 'name') as name,
      nullif(btrim(item ->> 'category'), '') as category,
      nullif(btrim(item ->> 'address'), '') as address,
      case
        when jsonb_typeof(item -> 'latitude') = 'number'
        then (item ->> 'latitude')::numeric
        else null
      end as latitude,
      case
        when jsonb_typeof(item -> 'longitude') = 'number'
        then (item ->> 'longitude')::numeric
        else null
      end as longitude,
      case
        when jsonb_typeof(item -> 'rating') = 'number'
        then (item ->> 'rating')::numeric
        else null
      end as rating,
      case when jsonb_typeof(item -> 'raw') = 'object' then item -> 'raw' end as raw
    from jsonb_array_elements(p_places) with ordinality as elems(item, ordinality)
  ), cleaned as (
    select * from incoming
    where provider_place_id is not null and provider_place_id <> ''
      and name is not null and name <> ''
      and (latitude is null) = (longitude is null)
      and (rating is null or (rating >= 0 and rating <= 5))
  ), valid as (
    select distinct on (provider_place_id) *
    from cleaned
    order by provider_place_id, ordinality
  ), upserted as (
    insert into public.places as p (
      provider, provider_place_id, name, category, address,
      latitude, longitude, rating, coordinate_system, raw, fetched_at
    )
    select
      'amap', provider_place_id, name, category, address,
      latitude, longitude, rating, 'gcj02', raw, now_ts
    from valid
    on conflict (provider, provider_place_id) do update set
      name = excluded.name,
      category = excluded.category,
      address = excluded.address,
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      rating = excluded.rating,
      raw = excluded.raw,
      fetched_at = excluded.fetched_at
    returning p.id, p.provider_place_id
  )
  select array_agg(upserted.id order by valid.ordinality)
  into ordered_ids
  from valid
  join upserted on upserted.provider_place_id = valid.provider_place_id;

  ordered_ids := coalesce(ordered_ids, '{}'::uuid[]);

  insert into public.place_searches (
    provider, search_kind, query_hash, query_params, place_ids, fetched_at
  )
  values (
    'amap', p_search_kind, public.place_search_query_hash(p_query_params),
    p_query_params, ordered_ids, now_ts
  )
  on conflict (provider, search_kind, query_hash) do update set
    place_ids = excluded.place_ids,
    query_params = excluded.query_params,
    fetched_at = excluded.fetched_at;

  select coalesce(
    jsonb_agg(public.place_public_json(p) order by ordered.ordinality),
    '[]'::jsonb
  )
  into places_json
  from unnest(ordered_ids) with ordinality as ordered(place_id, ordinality)
  join public.places p on p.id = ordered.place_id;

  return jsonb_build_object(
    'fetched_at', now_ts,
    'from_cache', false,
    'places', places_json
  );
end;
$$;

revoke all on function public.lookup_place_search(text, jsonb, integer)
  from public, anon, authenticated;
revoke all on function public.upsert_amap_places(text, jsonb, jsonb)
  from public, anon, authenticated;
revoke all on function public.place_public_json(public.places)
  from public, anon, authenticated;
