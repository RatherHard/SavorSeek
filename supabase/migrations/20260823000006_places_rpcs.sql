-- 地点缓存的读写函数。
--
-- 这两个函数是服务端内部接口，不授予 authenticated。
--
-- 原因是 places 为全体用户共享的公共数据：一旦把 upsert 开放给客户端，任何持
-- 有登录态的人都能绕过 Edge Function 往公共地点表里灌入伪造条目，污染面是所有
-- 用户，而不只是他自己的数据。因此写入只经 service_role 调用，调用方身份由
-- Edge Function 用调用者 JWT 显式校验（Kong 上只有 key-auth，校验的是 anon
-- key 而非用户 JWT，且 edge-runtime 的 VERIFY_JWT 对 main 服务无效，所以这层
-- 校验必须在函数代码里做）。
--
-- 函数体内不再重复 auth.uid() 判空：service_role 下它恒为 null，写在这里只会
-- 让唯一的合法调用方失败，形成「看似有校验、实际是死代码」的错觉。
--
-- query_hash 在库内由 query_params 计算，不接受调用方传入：jsonb 的文本表示
-- 键序固定，库内算一次即可消除「两侧哈希算法不一致导致缓存永不命中」这类
-- 沉默故障。

create or replace function public.place_search_query_hash(p_query_params jsonb)
returns bytea
language sql
immutable
set search_path = public, extensions, pg_temp
as $$ select digest(p_query_params::text, 'sha256'); $$;

-- 按查询参数取缓存。命中且未过期时返回按相关性排序的地点数组，否则返回 null。
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

  -- 用 unnest 的下标复原高德返回的相关性顺序；直接 join 会丢序。
  select coalesce(jsonb_agg(to_jsonb(p) order by ordered.ordinality), '[]'::jsonb)
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

-- upsert 一批高德地点并记下本次检索。返回与 lookup_place_search 同形状的结果，
-- 让调用方对「缓存命中」与「刚回源」走同一条解析分支。
--
-- p_places 为数组，每项形如：
--   {"provider_place_id":"B0FF...","name":"...","category":"...",
--    "address":"...","latitude":38.914003,"longitude":121.614682,
--    "raw":{"tel":"...","typecode":"..."}}
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

  -- 单条语句完成整批 upsert 并按入参顺序收集 id：逐条循环会让 N 个地点产生
  -- N 次往返，且顺序需要额外变量维护。
  with incoming as (
    select
      ordinality,
      btrim(item ->> 'provider_place_id') as provider_place_id,
      btrim(item ->> 'name') as name,
      nullif(btrim(item ->> 'category'), '') as category,
      nullif(btrim(item ->> 'address'), '') as address,
      (item ->> 'latitude')::numeric as latitude,
      (item ->> 'longitude')::numeric as longitude,
      case when jsonb_typeof(item -> 'raw') = 'object' then item -> 'raw' end as raw
    from jsonb_array_elements(p_places) with ordinality as elems(item, ordinality)
  ), cleaned as (
    -- 高德偶有 location 为空串或 name 缺失的条目，静默跳过而非整批失败：
    -- 一条脏数据不应让整次检索对用户表现为错误。
    select * from incoming
    where provider_place_id is not null and provider_place_id <> ''
      and name is not null and name <> ''
      and (latitude is null) = (longitude is null)
  ), valid as (
    -- 同一批里去重。高德跨页或近距检索会返回重复 POI，而一条 INSERT ... ON
    -- CONFLICT 语句里出现两行同键会直接报 21000（cannot affect row a second
    -- time），整批写入失败。保留首次出现的位置，与相关性顺序一致。
    select distinct on (provider_place_id) *
    from cleaned
    order by provider_place_id, ordinality
  ), upserted as (
    insert into public.places as p (
      provider, provider_place_id, name, category, address,
      latitude, longitude, coordinate_system, raw, fetched_at
    )
    select
      'amap', provider_place_id, name, category, address,
      latitude, longitude, 'gcj02', raw, now_ts
    from valid
    on conflict (provider, provider_place_id) do update set
      name = excluded.name,
      category = excluded.category,
      address = excluded.address,
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      raw = excluded.raw,
      fetched_at = excluded.fetched_at
    returning p.id, p.provider_place_id
  )
  select array_agg(upserted.id order by valid.ordinality)
  into ordered_ids
  from valid
  join upserted on upserted.provider_place_id = valid.provider_place_id;

  ordered_ids := coalesce(ordered_ids, '{}'::uuid[]);

  insert into public.place_searches (provider, search_kind, query_hash, query_params, place_ids, fetched_at)
  values (
    'amap', p_search_kind, public.place_search_query_hash(p_query_params),
    p_query_params, ordered_ids, now_ts
  )
  on conflict (provider, search_kind, query_hash) do update set
    place_ids = excluded.place_ids,
    query_params = excluded.query_params,
    fetched_at = excluded.fetched_at;

  select coalesce(jsonb_agg(to_jsonb(p) order by ordered.ordinality), '[]'::jsonb)
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

-- 三者都不授予 anon / authenticated：客户端读地点走 places 表的 select 策略，
-- 检索与写入一律经 Edge Function。service_role 作为超级角色无需显式 grant。
revoke all on function public.place_search_query_hash(jsonb) from public, anon, authenticated;
revoke all on function public.lookup_place_search(text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.upsert_amap_places(text, jsonb, jsonb) from public, anon, authenticated;
