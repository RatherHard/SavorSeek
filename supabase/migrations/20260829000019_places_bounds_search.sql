-- Bounds search cache support and structured filter field persistence.
-- This forward migration leaves prior places migrations unchanged.

alter table public.place_searches
  drop constraint if exists place_searches_kind_ck;
alter table public.place_searches
  add constraint place_searches_kind_ck check (search_kind in ('text', 'around', 'bounds'));

create or replace function public.place_public_json(p public.places)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', p.id,
    'provider_place_id', p.provider_place_id,
    'provenance', case p.provider
      when 'amap' then '高德地图'
      when 'manual' then '人工录入'
      else null
    end,
    'coordinate_system', p.coordinate_system,
    'name', p.name,
    'category', p.category,
    'address', p.address,
    'latitude', p.latitude,
    'longitude', p.longitude,
    'rating', p.rating,
    'cuisine_tags', p.cuisine_tags,
    'price_level', p.price_level,
    'business_status', p.business_status,
    'fetched_at', p.fetched_at
  );
$$;

revoke all on function public.place_public_json(public.places)
  from public, anon, authenticated;

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
  if p_search_kind not in ('text', 'around', 'bounds') then
    raise exception using errcode = '22023', message = 'search_kind must be text, around, or bounds';
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
      case when jsonb_typeof(item -> 'latitude') = 'number' then (item ->> 'latitude')::numeric end as latitude,
      case when jsonb_typeof(item -> 'longitude') = 'number' then (item ->> 'longitude')::numeric end as longitude,
      case when jsonb_typeof(item -> 'rating') = 'number' then (item ->> 'rating')::numeric end as rating,
      case when jsonb_typeof(item -> 'cuisine_tags') = 'array' then item -> 'cuisine_tags' end as cuisine_tags_json,
      case when jsonb_typeof(item -> 'price_level') = 'number' then (item ->> 'price_level')::smallint end as price_level,
      nullif(btrim(item ->> 'business_status'), '') as business_status,
      case when jsonb_typeof(item -> 'raw') = 'object' then item -> 'raw' end as raw
    from jsonb_array_elements(p_places) with ordinality as elems(item, ordinality)
  ), cleaned as (
    select * from incoming
    where provider_place_id is not null and provider_place_id <> ''
      and name is not null and name <> ''
      and (latitude is null) = (longitude is null)
      and (rating is null or (rating >= 0 and rating <= 5))
      and (price_level is null or price_level between 1 and 4)
      and (business_status is null or business_status in ('open', 'closed', 'unknown'))
      and (cuisine_tags_json is null or jsonb_typeof(cuisine_tags_json) = 'array')
  ), valid as (
    select distinct on (provider_place_id) *
    from cleaned
    order by provider_place_id, ordinality
  ), upserted as (
    insert into public.places as p (
      provider, provider_place_id, name, category, address,
      latitude, longitude, rating, cuisine_tags, price_level, business_status,
      price_observed_at, business_status_observed_at,
      coordinate_system, raw, fetched_at
    )
    select
      'amap', provider_place_id, name, category, address,
      latitude, longitude, rating,
      case when cuisine_tags_json is null then null else array(
        select jsonb_array_elements_text(cuisine_tags_json)
      ) end,
      price_level, business_status,
      case when price_level is null then null else now_ts end,
      case when business_status is null then null else now_ts end,
      'gcj02', raw, now_ts
    from valid
    on conflict (provider, provider_place_id) do update set
      name = excluded.name,
      category = excluded.category,
      address = excluded.address,
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      rating = excluded.rating,
      cuisine_tags = excluded.cuisine_tags,
      price_level = excluded.price_level,
      business_status = excluded.business_status,
      price_observed_at = excluded.price_observed_at,
      business_status_observed_at = excluded.business_status_observed_at,
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

revoke all on function public.upsert_amap_places(text, jsonb, jsonb)
  from public, anon, authenticated;
