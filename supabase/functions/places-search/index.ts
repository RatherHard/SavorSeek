/**
 * places-search：地点检索的服务端入口。
 *
 * 请求形状（POST，JSON）：
 *   文本检索  {"kind":"text","keywords":"烧烤","city":"大连","page":1}
 *   周边检索  {"kind":"around","latitude":38.914,"longitude":121.614,
 *              "radius":3000,"keywords":"烧烤","page":1}
 *
 * 响应形状：
 *   成功  {"places":[...],"fetched_at":"...","from_cache":true|false}
 *   失败  {"error":{"code":"provider_key_missing","message":"..."}}
 *
 * 身份校验必须在本文件里做，不能依赖平台配置：
 *   - Kong 上挂的是 key-auth + acl，校验的是 anon key（代表「未认证访客」这一
 *     身份），不校验用户 JWT；
 *   - edge-runtime 的 VERIFY_JWT 环境变量对 main 服务无效（见部署记录）。
 * 若不在此显式校验，任何持有 anon key（本就随客户端分发）的人都能免登录消耗
 * 高德配额。
 *
 * 两个 client 的分工是本文件的核心约束：
 *   userClient    带调用者 JWT，仅用于确认「你是谁」；
 *   serviceClient 带 service_role，仅用于读写 places 缓存。
 * places 是全体用户共享的公共数据，其写入函数因此不授予 authenticated（否则
 * 任何登录用户都能往公共表里灌伪造数据，污染面是所有人）。
 */
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import {
  type AmapQuery,
  type NormalizedPlace,
  AMAP_EXTENSIONS,
  PAGE_SIZE,
  PLACE_RESPONSE_CONTRACT_VERSION,
  requireAmapKey,
  searchAmapPlaces,
} from './amap.ts';
import {
  corsHeaders,
  errorResponse,
  jsonHeaders,
  PlacesSearchError,
} from './errors.ts';
import {
  type SearchBounds,
  planSearchPartitions,
} from './partition.ts';

/** 缓存有效期。地点的名称、地址与类别变动缓慢，一天足够新鲜。 */
const CACHE_TTL_SECONDS = 86_400;

/** 周边检索半径上限，与高德接口约定一致。 */
const MAX_RADIUS_METERS = 50_000;

const MAX_PAGE = 10;
const MAX_BOUNDS_SPAN_DEGREES = 20;
const MAX_RESULT_LIMIT = 100;
const BOUNDS_MAX_CALLS = 4;
const BOUNDS_CONCURRENCY = 2;

type SearchQuery = AmapQuery | BoundsSearchQuery;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    if (req.method !== 'POST') {
      throw new PlacesSearchError('invalid_request', '仅支持 POST 请求。');
    }

    const { userClient, serviceClient } = createClients(req);
    await requireUser(userClient);

    const query = parseQuery(await readJsonBody(req));
    const result = await resolveSearch(serviceClient, query);

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, ...jsonHeaders },
    });
  } catch (error) {
    return errorResponse(error);
  }
});

interface Clients {
  userClient: SupabaseClient;
  serviceClient: SupabaseClient;
}

function createClients(req: Request): Clients {
  const url = requireEnv('SUPABASE_URL');
  const anonKey = requireEnv('SUPABASE_ANON_KEY');
  const serviceKey = requireEnv('SUPABASE_SERVICE_ROLE_KEY');

  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.toLowerCase().startsWith('bearer ')) {
    throw new PlacesSearchError(
      'unauthenticated',
      '请登录后再检索地点。',
      '缺少 Bearer Authorization 头',
    );
  }

  return {
    userClient: createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    }),
    serviceClient: createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    }),
  };
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new PlacesSearchError(
      'storage_failure',
      '服务端配置不完整，请联系管理员。',
      `环境变量 ${name} 未设置`,
    );
  }
  return value;
}

/**
 * 确认调用者是已登录用户。
 *
 * anon key 也能构造出合法的 Authorization 头，但 getUser 对它返回 null——这正是
 * 需要这一步的原因：区分「持有随客户端分发的 anon key」与「持有登录用户 JWT」。
 */
async function requireUser(userClient: SupabaseClient): Promise<void> {
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) {
    throw new PlacesSearchError(
      'unauthenticated',
      '登录状态已失效，请重新登录后检索。',
      error?.message ?? 'getUser 返回空用户',
    );
  }
}

async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    throw new PlacesSearchError('invalid_request', '请求体不是合法的 JSON。');
  }
  if (
    typeof payload !== 'object' || payload === null || Array.isArray(payload)
  ) {
    throw new PlacesSearchError('invalid_request', '请求体必须是 JSON 对象。');
  }
  return payload as Record<string, unknown>;
}

function parseQuery(body: Record<string, unknown>): SearchQuery {
  if (body.kind === 'bounds') return parseBoundsQuery(body);
  const page = parsePage(body.page);

  if (body.kind === 'text') {
    const keywords = readTrimmed(body.keywords);
    if (!keywords) {
      throw new PlacesSearchError('invalid_request', '请输入要查找的关键词。');
    }
    if (keywords.length > 80) {
      throw new PlacesSearchError(
        'invalid_request',
        '关键词过长，请精简后重试。',
      );
    }
    return { kind: 'text', keywords, city: readTrimmed(body.city), page };
  }

  if (body.kind === 'around') {
    // 视野无效必须与「查无结果」分开：设计文档 §12 把二者列为不同的空结果成因。
    const latitude = parseCoordinate(body.latitude, 90, '纬度');
    const longitude = parseCoordinate(body.longitude, 180, '经度');
    const radius = parseRadius(body.radius);
    return {
      kind: 'around',
      latitude,
      longitude,
      radius,
      keywords: readTrimmed(body.keywords),
      page,
    };
  }

  throw new PlacesSearchError(
    'invalid_request',
    'kind 必须是 text 或 around。',
  );
}

function parsePage(value: unknown): number {
  if (value === undefined || value === null) return 1;
  const page = Number(value);
  if (!Number.isInteger(page) || page < 1 || page > MAX_PAGE) {
    throw new PlacesSearchError(
      'invalid_request',
      `page 必须是 1 到 ${MAX_PAGE} 之间的整数。`,
    );
  }
  return page;
}

interface BoundsSearchQuery {
  kind: 'bounds';
  bounds: SearchBounds;
  origin?: { latitude: number; longitude: number };
  keywords?: string;
  city?: string;
  filters: {
    cuisine_tags: string[];
    min_price_level?: number;
    max_price_level?: number;
    max_distance_meters?: number;
    open_now?: boolean;
    min_rating?: number;
  };
  limit: number;
  cursor?: string;
}

function parseBoundsQuery(body: Record<string, unknown>): BoundsSearchQuery {
  const rawBounds = body.bounds;
  if (typeof rawBounds !== 'object' || rawBounds === null || Array.isArray(rawBounds)) {
    throw new PlacesSearchError('invalid_request', 'bounds 必须是 JSON 对象。');
  }
  const bounds = rawBounds as Record<string, unknown>;
  const south = parseCoordinate(bounds.south, 90, '南纬');
  const north = parseCoordinate(bounds.north, 90, '北纬');
  const west = parseCoordinate(bounds.west, 180, '西经');
  const east = parseCoordinate(bounds.east, 180, '东经');
  if (south > north) {
    throw new PlacesSearchError('invalid_request', 'bounds 的南北边界无效。');
  }
  if (north - south > MAX_BOUNDS_SPAN_DEGREES) {
    throw new PlacesSearchError('invalid_request', '地图范围过大，请放大地图后重试。');
  }
  const rawFilters = body.filters;
  const filters = parseFilters(rawFilters);
  const limit = parseLimit(body.limit);
  const rawOrigin = body.origin;
  const origin = rawOrigin === undefined || rawOrigin === null
    ? undefined
    : (() => {
      if (typeof rawOrigin !== 'object' || Array.isArray(rawOrigin)) {
        throw new PlacesSearchError('invalid_request', 'origin 必须是 JSON 对象。');
      }
      const value = rawOrigin as Record<string, unknown>;
      return {
        latitude: parseCoordinate(value.latitude, 90, '起点纬度'),
        longitude: parseCoordinate(value.longitude, 180, '起点经度'),
      };
    })();
  if (origin === undefined && filters.max_distance_meters !== undefined) {
    throw new PlacesSearchError('invalid_request', '设置最大距离时必须提供 origin。');
  }
  const keywords = readTrimmed(body.keywords);
  if (keywords && keywords.length > 80) {
    throw new PlacesSearchError('invalid_request', '关键词过长，请精简后重试。');
  }
  return {
    kind: 'bounds',
    bounds: { south, west, north, east },
    origin,
    keywords,
    city: readTrimmed(body.city),
    filters,
    limit,
    cursor: readTrimmed(body.cursor),
  };
}

function parseFilters(value: unknown): BoundsSearchQuery['filters'] {
  if (value === undefined || value === null) {
    return { cuisine_tags: [] };
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    throw new PlacesSearchError('invalid_request', 'filters 必须是 JSON 对象。');
  }
  const row = value as Record<string, unknown>;
  const cuisineValue = row.cuisine_tags;
  const cuisineTags = cuisineValue === undefined
    ? []
    : Array.isArray(cuisineValue) && cuisineValue.every((item) => typeof item === 'string')
    ? [...new Set(cuisineValue.map((item) => item.trim()).filter(Boolean))].sort()
    : (() => { throw new PlacesSearchError('invalid_request', '菜系筛选格式无效。'); })();
  if (cuisineTags.length > 20 || cuisineTags.some((tag) => tag.length > 40)) {
    throw new PlacesSearchError('invalid_request', '菜系筛选条件过多或过长。');
  }
  const minPrice = parseOptionalInteger(row.min_price_level, 1, 4, '最低价格');
  const maxPrice = parseOptionalInteger(row.max_price_level, 1, 4, '最高价格');
  if (minPrice !== undefined && maxPrice !== undefined && minPrice > maxPrice) {
    throw new PlacesSearchError('invalid_request', '价格范围无效。');
  }
  const maxDistance = parseOptionalInteger(
    row.max_distance_meters,
    1,
    MAX_RADIUS_METERS,
    '最大距离',
  );
  const minRating = parseOptionalNumber(row.min_rating, 0, 5, '最低评分');
  const openNow = row.open_now === undefined || row.open_now === null
    ? undefined
    : typeof row.open_now === 'boolean'
    ? row.open_now
    : (() => { throw new PlacesSearchError('invalid_request', '营业状态筛选格式无效。'); })();
  return {
    cuisine_tags: cuisineTags,
    ...(minPrice === undefined ? {} : { min_price_level: minPrice }),
    ...(maxPrice === undefined ? {} : { max_price_level: maxPrice }),
    ...(maxDistance === undefined ? {} : { max_distance_meters: maxDistance }),
    ...(openNow === undefined ? {} : { open_now: openNow }),
    ...(minRating === undefined ? {} : { min_rating: minRating }),
  };
}

function parseLimit(value: unknown): number {
  if (value === undefined || value === null) return 50;
  const limit = Number(value);
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_RESULT_LIMIT) {
    throw new PlacesSearchError('invalid_request', `limit 必须是 1 到 ${MAX_RESULT_LIMIT} 之间的整数。`);
  }
  return limit;
}

function parseOptionalInteger(
  value: unknown,
  min: number,
  max: number,
  label: string,
): number | undefined {
  if (value === undefined || value === null) return undefined;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
    throw new PlacesSearchError('invalid_request', `${label}必须在 ${min} 到 ${max} 之间。`);
  }
  return parsed;
}

function parseOptionalNumber(
  value: unknown,
  min: number,
  max: number,
  label: string,
): number | undefined {
  if (value === undefined || value === null) return undefined;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    throw new PlacesSearchError('invalid_request', `${label}必须在 ${min} 到 ${max} 之间。`);
  }
  return parsed;
}

function parseCoordinate(value: unknown, limit: number, label: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || Math.abs(parsed) > limit) {
    throw new PlacesSearchError(
      'invalid_request',
      `当前地图位置无效（${label}超出有效范围），请移动地图后重试。`,
    );
  }
  return parsed;
}

function parseRadius(value: unknown): number {
  if (value === undefined || value === null) return 3000;
  const radius = Number(value);
  if (!Number.isFinite(radius) || radius < 1 || radius > MAX_RADIUS_METERS) {
    throw new PlacesSearchError(
      'invalid_request',
      `检索半径必须在 1 到 ${MAX_RADIUS_METERS} 米之间。`,
    );
  }
  return Math.round(radius);
}

function readTrimmed(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

interface SearchResult {
  places: unknown[];
  fetched_at: string | null;
  from_cache: boolean;
  count?: number;
  has_more?: boolean;
  partial?: boolean;
  failed_tiles?: string[];
}

/** 先查缓存，未命中再回源高德并落库。 */
async function resolveSearch(
  serviceClient: SupabaseClient,
  query: SearchQuery,
): Promise<SearchResult> {
  if (query.kind === 'bounds') {
    return resolveBoundsSearch(serviceClient, query);
  }
  // 缓存键由归一化参数构成，与请求体无关：客户端多传的字段不该造成缓存穿透。
  const queryParams = toQueryParams(query);

  const cached = await rpc(serviceClient, 'lookup_place_search', {
    p_search_kind: query.kind,
    p_query_params: queryParams,
    p_ttl_seconds: CACHE_TTL_SECONDS,
  });
  if (cached) return cached as SearchResult;

  // Key 在这一步才读取：缓存命中的请求不该因服务端未配置 Key 而失败。
  const places = await searchAmapPlaces(query, requireAmapKey());

  const stored = await rpc(serviceClient, 'upsert_amap_places', {
    p_search_kind: query.kind,
    p_query_params: queryParams,
    p_places: places,
  });
  return (stored ?? {
    places: [],
    fetched_at: null,
    from_cache: false,
  }) as SearchResult;
}

async function resolveBoundsSearch(
  serviceClient: SupabaseClient,
  query: BoundsSearchQuery,
): Promise<SearchResult> {
  const params = toBoundsQueryParams(query);
  const cached = await rpc(serviceClient, 'lookup_place_search', {
    p_search_kind: 'bounds',
    p_query_params: params,
    p_ttl_seconds: CACHE_TTL_SECONDS,
  });
  if (cached) return applyBoundsResult(cached as SearchResult, query);

  const key = requireAmapKey();
  const partitions = planSearchPartitions(query.bounds).slice(0, BOUNDS_MAX_CALLS);
  const settled = await mapWithConcurrency(partitions, BOUNDS_CONCURRENCY, async (tile) => {
    try {
      const places = await searchAmapPlaces({
        kind: 'around',
        latitude: tile.latitude,
        longitude: tile.longitude,
        radius: tile.radius,
        keywords: query.keywords,
        page: 1,
      }, key);
      return { tile: tile.key, places };
    } catch (error) {
      return { tile: tile.key, error };
    }
  });
  const failures = settled.filter((item): item is { tile: string; error: unknown } => 'error' in item);
  const succeeded = settled.filter((item): item is { tile: string; places: NormalizedPlace[] } => 'places' in item);
  if (succeeded.length === 0) {
    const firstError = failures[0]?.error;
    if (firstError instanceof PlacesSearchError) throw firstError;
    throw new PlacesSearchError('provider_unavailable', '地点检索服务暂时不可用，请稍后重试。');
  }

  const merged = filterBoundsPlaces(
    dedupePlaces(succeeded.flatMap((item) => item.places)),
    query,
  );
  const stored = failures.length === 0
    ? await rpc(serviceClient, 'upsert_amap_places', {
      p_search_kind: 'bounds',
      p_query_params: params,
      p_places: merged,
    })
    : null;
  const result = (stored ?? {
    places: merged,
    fetched_at: new Date().toISOString(),
    from_cache: false,
  }) as SearchResult;
  return {
    ...applyBoundsResult(result, query),
    partial: failures.length > 0,
    failed_tiles: failures.map((failure) => failure.tile),
  };
}

async function mapWithConcurrency<T, R>(
  values: T[],
  concurrency: number,
  task: (value: T) => Promise<R>,
): Promise<R[]> {
  const results: R[] = [];
  let next = 0;
  async function worker(): Promise<void> {
    while (next < values.length) {
      const index = next++;
      results[index] = await task(values[index]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, worker));
  return results;
}

function dedupePlaces(places: NormalizedPlace[]): NormalizedPlace[] {
  const seen = new Set<string>();
  return places.filter((place) => {
    if (seen.has(place.provider_place_id)) return false;
    seen.add(place.provider_place_id);
    return true;
  });
}

function filterBoundsPlaces(places: NormalizedPlace[], query: BoundsSearchQuery): NormalizedPlace[] {
  return places.filter((place) => {
    if (place.latitude === null || place.longitude === null) return false;
    const { latitude, longitude } = place;
    const insideLongitude = query.bounds.west <= query.bounds.east
      ? longitude >= query.bounds.west && longitude <= query.bounds.east
      : longitude >= query.bounds.west || longitude <= query.bounds.east;
    if (latitude < query.bounds.south || latitude > query.bounds.north || !insideLongitude) return false;
    const filters = query.filters;
    if (filters.cuisine_tags.length > 0 && !filters.cuisine_tags.some((tag) =>
      place.cuisine_tags?.some((candidate) => candidate.toLowerCase() === tag.toLowerCase())
    )) return false;
    if (filters.min_price_level !== undefined &&
      (place.price_level === null || place.price_level < filters.min_price_level)) return false;
    if (filters.max_price_level !== undefined &&
      (place.price_level === null || place.price_level > filters.max_price_level)) return false;
    if (filters.min_rating !== undefined &&
      (place.rating === null || place.rating < filters.min_rating)) return false;
    if (filters.open_now !== undefined) {
      const isOpen = place.business_status === 'open';
      if (isOpen !== filters.open_now) return false;
    }
    if (query.origin && filters.max_distance_meters !== undefined &&
      distanceMeters(query.origin.latitude, query.origin.longitude, latitude, longitude) > filters.max_distance_meters) return false;
    return true;
  }).sort((left, right) => (right.rating ?? -1) - (left.rating ?? -1) ||
    left.provider_place_id.localeCompare(right.provider_place_id)).slice(0, query.limit);
}

function distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const radians = Math.PI / 180;
  const dLat = (lat2 - lat1) * radians;
  const dLon = (lon2 - lon1) * radians;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * radians) * Math.cos(lat2 * radians) * Math.sin(dLon / 2) ** 2;
  return 6_371_000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function applyBoundsResult(result: SearchResult, query: BoundsSearchQuery): SearchResult {
  const places = filterBoundsPlaces(result.places as NormalizedPlace[], query);
  return { ...result, places, count: places.length, has_more: places.length >= query.limit };
}

function toBoundsQueryParams(
  query: BoundsSearchQuery,
): Record<string, unknown> {
  return {
    bounds: query.bounds,
    city: query.city ?? null,
    keywords: query.keywords ?? null,
    filters: query.filters,
    limit: query.limit,
    cursor: query.cursor ?? null,
    contract_version: 'places-filter-v1',
  };
}

/** 归一化查询参数。键序固定，缺省项显式补齐，避免等价查询算出不同哈希。 */
function toQueryParams(query: AmapQuery): Record<string, unknown> {
  if (query.kind === 'text') {
    return {
      city: query.city ?? null,
      keywords: query.keywords,
      page: query.page,
      page_size: PAGE_SIZE,
      extensions: AMAP_EXTENSIONS,
      contract_version: PLACE_RESPONSE_CONTRACT_VERSION,
    };
  }
  return {
    keywords: query.keywords ?? null,
    // 坐标按 6 位小数归一：更高精度对 POI 检索无意义，却会让相邻请求全部穿透缓存。
    latitude: Number(query.latitude.toFixed(6)),
    longitude: Number(query.longitude.toFixed(6)),
    page: query.page,
    page_size: PAGE_SIZE,
    radius: query.radius,
    extensions: AMAP_EXTENSIONS,
    contract_version: PLACE_RESPONSE_CONTRACT_VERSION,
  };
}

async function rpc(
  client: SupabaseClient,
  name: string,
  params: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await client.rpc(name, params);
  if (error) {
    throw new PlacesSearchError(
      'storage_failure',
      '地点数据读写失败，请稍后重试。',
      `${name}: ${error.code ?? ''} ${error.message}`,
    );
  }
  return data;
}
