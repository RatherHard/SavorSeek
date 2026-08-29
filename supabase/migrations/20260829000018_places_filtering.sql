-- Structured place filtering fields. All provider fields remain nullable: absence is unknown.
alter table public.place_searches
  drop constraint if exists place_searches_kind_ck;
alter table public.place_searches
  add constraint place_searches_kind_ck check (search_kind in ('text', 'around', 'bounds'));

alter table public.places
  add column if not exists cuisine_tags text[],
  add column if not exists price_level smallint,
  add column if not exists business_status text,
  add column if not exists price_observed_at timestamptz,
  add column if not exists business_status_observed_at timestamptz;

alter table public.places
  drop constraint if exists places_price_level_ck;
alter table public.places
  add constraint places_price_level_ck check (
    price_level is null or price_level between 1 and 4
  );

alter table public.places
  drop constraint if exists places_business_status_ck;
alter table public.places
  add constraint places_business_status_ck check (
    business_status is null
    or business_status in ('open', 'closed', 'unknown')
  );

alter table public.places
  drop constraint if exists places_cuisine_tags_ck;
alter table public.places
  add constraint places_cuisine_tags_ck check (
    cuisine_tags is null or cardinality(cuisine_tags) <= 32
  );

create index if not exists places_filter_lat_lng_idx
  on public.places (latitude, longitude, id)
  where coordinate_system = 'gcj02'
    and latitude is not null
    and longitude is not null;

create index if not exists places_cuisine_tags_gin_idx
  on public.places using gin (cuisine_tags);

-- Public clients use the Edge Function projection, not the raw cache table.
revoke select on table public.places from anon, authenticated;
drop policy if exists places_select_all on public.places;

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
    'cuisine_tags', p.cuisine_tags,
    'price_level', p.price_level,
    'business_status', p.business_status,
    'fetched_at', p.fetched_at
  );
$$;

revoke all on function public.place_public_json(public.places)
  from public, anon, authenticated;
