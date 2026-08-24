/**
 * trip-route：行程路线规划的服务端入口。
 *
 * 请求形状（POST，JSON）：
 *   {"points":[{"latitude":38.914,"longitude":121.614},
 *              {"latitude":38.920,"longitude":121.620}],
 *    "mode":"walking"}
 *
 * 响应形状：
 *   成功  {"path":[{"latitude":...,"longitude":...},...],"mode":"walking"}
 *   失败  {"error":{"code":"provider_key_missing","message":"..."}}
 *
 * 身份校验必须在本文件里做，不能依赖平台配置（与 places-search 同因）：
 *   - Kong 上挂的是 key-auth + acl，校验的是 anon key（代表「未认证访客」这一
 *     身份），不校验用户 JWT；
 *   - edge-runtime 的 VERIFY_JWT 环境变量对 main 服务无效。
 * 若不在此显式校验，任何持有 anon key（本就随客户端分发）的人都能免登录消耗
 * 高德配额。
 */
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import {
  type GeoPoint,
  requireAmapKey,
  resolveRoute,
  type TravelMode,
} from './amap.ts';
import {
  corsHeaders,
  errorResponse,
  jsonHeaders,
  TripRouteError,
} from './errors.ts';

/**
 * 单次请求的节点上限。
 *
 * N 个节点要发 N-1 次高德请求，不设上限会让一条长行程一次吃掉大量配额，
 * 也会让函数执行时间线性增长直到超时。
 */
const MAX_POINTS = 12;

const TRAVEL_MODES: ReadonlySet<string> = new Set([
  'walking',
  'driving',
  'bicycling',
]);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    if (req.method !== 'POST') {
      throw new TripRouteError('invalid_request', '仅支持 POST 请求。');
    }

    await requireUser(createUserClient(req));

    const body = await readJsonBody(req);
    const points = parsePoints(body.points);
    const mode = parseMode(body.mode);

    // Key 在校验通过后才读取：未登录的请求不该因服务端未配置 Key 而返回配置错误。
    const path = await resolveRoute(points, mode, requireAmapKey());

    return new Response(JSON.stringify({ path, mode }), {
      headers: { ...corsHeaders, ...jsonHeaders },
    });
  } catch (error) {
    return errorResponse(error);
  }
});

/**
 * 构造带调用者 JWT 的客户端，仅用于确认「你是谁」。
 *
 * 本函数不读写数据库，因此不需要 service_role 客户端——路线是纯代理，
 * 引入更高权限的凭据只会扩大受攻击面。
 */
function createUserClient(req: Request): SupabaseClient {
  const url = requireEnv('SUPABASE_URL');
  const anonKey = requireEnv('SUPABASE_ANON_KEY');

  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.toLowerCase().startsWith('bearer ')) {
    throw new TripRouteError(
      'unauthenticated',
      '请登录后再规划路线。',
      '缺少 Bearer Authorization 头',
    );
  }

  return createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new TripRouteError(
      'provider_unavailable',
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
    throw new TripRouteError(
      'unauthenticated',
      '登录状态已失效，请重新登录后规划路线。',
      error?.message ?? 'getUser 返回空用户',
    );
  }
}

async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    throw new TripRouteError('invalid_request', '请求体不是合法的 JSON。');
  }
  if (
    typeof payload !== 'object' || payload === null || Array.isArray(payload)
  ) {
    throw new TripRouteError('invalid_request', '请求体必须是 JSON 对象。');
  }
  return payload as Record<string, unknown>;
}

function parsePoints(value: unknown): GeoPoint[] {
  if (!Array.isArray(value) || value.length < 2) {
    throw new TripRouteError(
      'invalid_request',
      '至少需要两个坐标点才能规划路线。',
    );
  }
  if (value.length > MAX_POINTS) {
    throw new TripRouteError(
      'invalid_request',
      `一次最多规划 ${MAX_POINTS} 个节点的路线。`,
    );
  }
  return value.map((point) => {
    if (typeof point !== 'object' || point === null) {
      throw new TripRouteError('invalid_request', '坐标点必须是对象。');
    }
    const row = point as Record<string, unknown>;
    return {
      latitude: parseCoordinate(row.latitude, 90, '纬度'),
      longitude: parseCoordinate(row.longitude, 180, '经度'),
    };
  });
}

function parseCoordinate(value: unknown, limit: number, label: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || Math.abs(parsed) > limit) {
    throw new TripRouteError(
      'invalid_request',
      `坐标无效（${label}超出有效范围）。`,
    );
  }
  return parsed;
}

/** 缺省步行：美食行程的相邻两点多在同一街区，步行是最贴近实际的默认值。 */
function parseMode(value: unknown): TravelMode {
  if (value === undefined || value === null) return 'walking';
  if (typeof value !== 'string' || !TRAVEL_MODES.has(value)) {
    throw new TripRouteError(
      'invalid_request',
      'mode 必须是 walking、driving 或 bicycling。',
    );
  }
  return value as TravelMode;
}
