-- 公共地点数据与检索缓存。
--
-- 与行程四表的权限模型一致：客户端只读，写入全部经 security definer 函数，
-- 但边界不同——地点是公共数据，不按 user_id 隔离，`authenticated` 整表可读。
--
-- 坐标存两个 numeric 列而非 postgis geography：本阶段的地理过滤在高德侧完成，
-- 库内只需按 (provider, provider_place_id) 命中缓存。等出现「库内查附近」的
-- 真实需求再引入 postgis（实例已具备 3.3.7，可后续迁移平滑升级）。

create table if not exists public.places (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_place_id text not null,
  name varchar(120) not null,
  category text,
  address varchar(300),
  latitude numeric(9, 6),
  longitude numeric(9, 6),
  coordinate_system text not null default 'gcj02',
  -- 供应商原始字段的最小子集，仅保留展示与溯源所需项。
  -- 不留存完整响应：高德服务条款限制缓存与二次分发范围，字段越少越安全。
  raw jsonb,
  fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint places_provider_ck check (provider in ('amap', 'manual')),
  constraint places_provider_place_id_ck check (char_length(btrim(provider_place_id)) between 1 and 128),
  constraint places_name_ck check (char_length(btrim(name)) between 1 and 120),
  -- 与 trip_items.place_snapshot 的校验保持同一套规则，快照由本表构造时才不会被
  -- 库端 trigger 拒绝（见 itinerary_schema.sql:248-259）。
  constraint places_coordinate_pair_ck check ((latitude is null) = (longitude is null)),
  constraint places_coordinate_range_ck check (
    latitude is null
    or (latitude between -90 and 90 and longitude between -180 and 180)
  ),
  constraint places_coordinate_system_ck check (coordinate_system in ('gcj02', 'wgs84')),
  constraint places_raw_object_ck check (raw is null or jsonb_typeof(raw) = 'object'),
  constraint places_provider_uq unique (provider, provider_place_id)
);

create index if not exists places_fetched_at_idx on public.places (fetched_at desc);
create index if not exists places_name_idx on public.places (name);

-- 检索结果缓存。
--
-- 单靠 places 无法判断「这条查询是否已服务过」：文本检索的键是查询本身，不是
-- 地点。故按查询参数哈希单独留一张表，place_ids 保留高德返回的相关性顺序。
create table if not exists public.place_searches (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  search_kind text not null,
  query_hash bytea not null,
  -- 归一化后的查询参数，用于排查哈希碰撞与复现问题，不参与匹配。
  query_params jsonb not null,
  place_ids uuid[] not null default '{}',
  fetched_at timestamptz not null default now(),
  constraint place_searches_provider_ck check (provider in ('amap')),
  constraint place_searches_kind_ck check (search_kind in ('text', 'around')),
  constraint place_searches_params_object_ck check (jsonb_typeof(query_params) = 'object'),
  constraint place_searches_uq unique (provider, search_kind, query_hash)
);

create index if not exists place_searches_fetched_at_idx on public.place_searches (fetched_at desc);

create or replace function public.validate_place_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.name := btrim(new.name);
  new.provider_place_id := btrim(new.provider_place_id);
  new.category := nullif(btrim(new.category), '');
  new.address := nullif(btrim(new.address), '');
  if tg_op = 'UPDATE' then
    -- 供应商标识是缓存键，改动等同于换了一个地点，只能新建行。
    if new.provider is distinct from old.provider
      or new.provider_place_id is distinct from old.provider_place_id then
      raise exception using errcode = '42501', message = 'place provider identity cannot be changed';
    end if;
    new.updated_at := clock_timestamp();
  end if;
  return new;
end;
$$;

create trigger places_validate_before_write before insert or update on public.places
for each row execute function public.validate_place_row();

-- trip_items.place_id 此前是无引用目标的裸 uuid。
-- on delete set null 而非 cascade：地点被删除或合并时，已排入行程的历史项必须
-- 保留（依靠 place_snapshot 保持可读），这是数据模型文档 §249 的明确要求。
alter table public.trip_items drop constraint if exists trip_items_place_fk;
alter table public.trip_items
  add constraint trip_items_place_fk foreign key (place_id)
  references public.places (id) on delete set null;

alter table public.places enable row level security;
alter table public.place_searches enable row level security;

-- 地点是公共数据，不按 user_id 隔离：任何登录用户都应看到同一份地点事实。
create policy places_select_all on public.places for select to authenticated
using (true);

-- 检索缓存不对客户端开放：它是服务端实现细节，暴露出去等于允许客户端枚举
-- 他人的查询历史。仅 security definer 函数与 service_role 可访问。
revoke all on public.places, public.place_searches from anon, authenticated;
grant select on public.places to authenticated;
revoke all on function public.validate_place_row() from public, anon, authenticated;
