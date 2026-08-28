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

/** 缓存有效期。地点的名称、地址与类别变动缓慢，一天足够新鲜。 */
const CACHE_TTL_SECONDS = 86_400;

/** 周边检索半径上限，与高德接口约定一致。 */
const MAX_RADIUS_METERS = 50_000;

const MAX_PAGE = 10;

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

function parseQuery(body: Record<string, unknown>): AmapQuery {
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
}

/** 先查缓存，未命中再回源高德并落库。 */
async function resolveSearch(
  serviceClient: SupabaseClient,
  query: AmapQuery,
): Promise<SearchResult> {
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
