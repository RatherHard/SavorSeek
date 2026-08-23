/**
 * 高德 Web 服务 API 的地点检索客户端。
 *
 * 为什么走服务端代理而不是客户端 SDK：`amap_map 1.0.15` 官方插件只提供地图显示
 * （`AMapWidget`），不含 POI 搜索。检索因此必须请求 Web 服务 API，而该 API 的
 * Key 一旦下发客户端就无法回收，配额也不可控。放在服务端还顺带让结果天然落库。
 *
 * 错误码语义见官方文档（https://lbs.amap.com/api/webservice/guide/tools/info）。
 * 分类原则：配置类错误直接失败并告警，重试永远不会成功；限流类才可退避重试。
 */
import { PlacesSearchError } from './errors.ts';

const AMAP_BASE = 'https://restapi.amap.com/v3/place';

/** 单次请求上限。高德默认 20，取 20 以减少翻页往返。 */
export const PAGE_SIZE = 20;

/** 请求超时。高德文本检索通常数百毫秒返回，8s 已足够宽松。 */
const TIMEOUT_MS = 8000;

/** Key 或权限配置错误：重试无意义，必须改配置。 */
const CONFIG_ERROR_CODES = new Set([
  '10001', // INVALID_USER_KEY        key 不正确或已过期
  '10002', // SERVICE_NOT_AVAILABLE   无此服务权限
  '10005', // INVALID_USER_IP         服务器出口 IP 不在白名单
  '10006', // INVALID_USER_DOMAIN     绑定域名无效
  '10008', // INVALID_USER_SCODE      安全码校验失败
  '10009', // USERKEY_PLAT_NOMATCH    key 与绑定平台不符（拿 SDK key 调 Web 服务）
  '10012', // INSUFFICIENT_PRIVILEGES 权限不足
  '10013', // USER_KEY_RECYCLED       key 已删除
  '10041', // NO_EFFECTIVE_INTERFACE  接口权限过期
]);

/** 限流与配额类：短期内重试或次日恢复。 */
const QUOTA_ERROR_CODES = new Set([
  '10003', // DAILY_QUERY_OVER_LIMIT       日访问量超限
  '10004', // ACCESS_TOO_FREQUENT          单分钟访问量超限
  '10010', // IP_QUERY_OVER_LIMIT          单 IP 超限
  '10014', // QPS_HAS_EXCEEDED_THE_LIMIT
  '10015', // GATEWAY_TIMEOUT              单机 QPS 限流
  '10019', // CQPS_HAS_EXCEEDED_THE_LIMIT
  '10020', // CKQPS_HAS_EXCEEDED_THE_LIMIT
  '10021', // CUQPS_HAS_EXCEEDED_THE_LIMIT
  '10044', // USER_DAILY_QUERY_OVER_LIMIT  账号维度日调用量超限
  '40000', // QUOTA_PLAN_RUN_OUT           余额耗尽
  '40002', // SERVICE_EXPIRED              购买服务到期
]);

/** 归一化后的地点，字段与 public.places 的列一一对应。 */
export interface NormalizedPlace {
  provider_place_id: string;
  name: string;
  category: string | null;
  address: string | null;
  latitude: number | null;
  longitude: number | null;
  raw: Record<string, string> | null;
}

interface AmapResponse {
  status?: string;
  info?: string;
  infocode?: string;
  count?: string;
  pois?: unknown;
}

/** 读取 Key。缺失与占位值都视为未配置：占位值会让高德返回 10001，误导排障。 */
export function requireAmapKey(): string {
  const key = Deno.env.get('AMAP_WEB_SERVICE_KEY')?.trim();
  if (!key || key === 'REPLACE_ME') {
    throw new PlacesSearchError(
      'provider_key_missing',
      '服务端未配置地点检索所需的密钥，请联系管理员。',
      '环境变量 AMAP_WEB_SERVICE_KEY 未设置或仍为占位值',
    );
  }
  return key;
}

export interface TextSearchQuery {
  kind: 'text';
  keywords: string;
  city?: string;
  page: number;
}

export interface AroundSearchQuery {
  kind: 'around';
  longitude: number;
  latitude: number;
  radius: number;
  keywords?: string;
  page: number;
}

export type AmapQuery = TextSearchQuery | AroundSearchQuery;

/** 执行检索，返回归一化地点列表。 */
export async function searchAmapPlaces(
  query: AmapQuery,
  key: string,
): Promise<NormalizedPlace[]> {
  const url = buildUrl(query, key);
  const payload = await fetchAmap(url);
  assertAmapOk(payload);
  return normalizePois(payload.pois);
}

function buildUrl(query: AmapQuery, key: string): URL {
  // 用 URL/searchParams 而非字符串拼接：关键词含 & = # 时手工拼接会篡改查询结构。
  const url = new URL(
    query.kind === 'text' ? `${AMAP_BASE}/text` : `${AMAP_BASE}/around`,
  );
  const params = url.searchParams;
  params.set('key', key);
  params.set('offset', String(PAGE_SIZE));
  params.set('page', String(query.page));
  // base 而非 all：extensions=all 会返回评分、图片、团购等字段，缓存范围越大
  // 合规风险越高。只取展示与溯源必需项。
  params.set('extensions', 'base');

  if (query.kind === 'text') {
    params.set('keywords', query.keywords);
    if (query.city) {
      params.set('city', query.city);
      // 限定城市后不再跨城扩散，避免「大连」查询返回外地同名店。
      params.set('citylimit', 'true');
    }
  } else {
    // 高德的 location 顺序是「经度,纬度」，与常见的 lat,lng 相反，写反会静默
    // 返回错误区域的结果而非报错。
    params.set('location', `${query.longitude},${query.latitude}`);
    params.set('radius', String(query.radius));
    if (query.keywords) params.set('keywords', query.keywords);
  }
  return url;
}

async function fetchAmap(url: URL): Promise<AmapResponse> {
  // AbortSignal.timeout 而非手工 setTimeout：后者忘记 clearTimeout 会让
  // Deno worker 因悬挂定时器延迟回收。
  let response: Response;
  try {
    response = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (error) {
    const isTimeout = error instanceof DOMException &&
      error.name === 'TimeoutError';
    throw new PlacesSearchError(
      'provider_unavailable',
      isTimeout ? '地点检索超时，请稍后重试。' : '暂时无法连接地点检索服务。',
      error instanceof Error ? error.message : String(error),
    );
  }

  if (!response.ok) {
    throw new PlacesSearchError(
      'provider_unavailable',
      '地点检索服务返回异常，请稍后重试。',
      `HTTP ${response.status}`,
    );
  }

  try {
    return await response.json() as AmapResponse;
  } catch (error) {
    throw new PlacesSearchError(
      'provider_unavailable',
      '地点检索服务返回了无法解析的内容。',
      error instanceof Error ? error.message : String(error),
    );
  }
}

/**
 * 校验高德的业务状态。
 *
 * 关键点：HTTP 200 不代表成功。高德把业务失败也放在 200 响应里，靠 status
 * 字段区分（"1" 成功、"0" 失败）。只看 HTTP 状态码会把「Key 无效」当成
 * 「查无结果」，正是设计文档 §12 要求避免的情形。
 */
function assertAmapOk(payload: AmapResponse): void {
  if (payload.status === '1') return;

  const infocode = payload.infocode ?? '';
  const detail = `infocode=${infocode} info=${payload.info ?? ''}`;

  if (CONFIG_ERROR_CODES.has(infocode)) {
    throw new PlacesSearchError(
      'provider_key_rejected',
      '地点检索服务的密钥配置有误，请联系管理员。',
      detail,
    );
  }
  if (QUOTA_ERROR_CODES.has(infocode)) {
    throw new PlacesSearchError(
      'provider_quota_exceeded',
      '地点检索请求过于频繁，请稍后重试。',
      detail,
    );
  }
  throw new PlacesSearchError(
    'provider_unavailable',
    '地点检索服务暂时不可用，请稍后重试。',
    detail,
  );
}

function normalizePois(pois: unknown): NormalizedPlace[] {
  // 高德在无结果时把 pois 返回为空数组，个别接口返回空字符串，故先判类型。
  if (!Array.isArray(pois)) return [];
  return pois
    .map(normalizePoi)
    .filter((place): place is NormalizedPlace => place !== null);
}

function normalizePoi(poi: unknown): NormalizedPlace | null {
  if (typeof poi !== 'object' || poi === null) return null;
  const row = poi as Record<string, unknown>;

  const id = readString(row.id);
  const name = readString(row.name);
  // 缺少 id 或 name 的条目无法入库（id 是缓存键，name 有非空约束），跳过而非
  // 整批失败：一条脏数据不该让整次检索对用户表现为错误。
  if (!id || !name) return null;

  const [longitude, latitude] = parseLocation(row.location);

  return {
    provider_place_id: id,
    name,
    category: readString(row.type),
    address: readString(row.address),
    latitude,
    longitude,
    raw: buildRaw(row),
  };
}

/** location 形如 "121.614682,38.914003"（经度在前）。 */
function parseLocation(value: unknown): [number | null, number | null] {
  const raw = readString(value);
  if (!raw) return [null, null];
  const [lngText, latText] = raw.split(',');
  const longitude = Number(lngText);
  const latitude = Number(latText);
  if (!Number.isFinite(longitude) || !Number.isFinite(latitude)) {
    return [null, null];
  }
  // 越界坐标会被库端 check 约束拒绝，导致整批 upsert 失败，故此处先剔除。
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return [null, null];
  return [longitude, latitude];
}

/** 只留展示与溯源必需的字段，不留存完整响应。 */
function buildRaw(row: Record<string, unknown>): Record<string, string> | null {
  const raw: Record<string, string> = {};
  for (
    const field of ['typecode', 'tel', 'pname', 'cityname', 'adname'] as const
  ) {
    const value = readString(row[field]);
    if (value) raw[field] = value;
  }
  return Object.keys(raw).length > 0 ? raw : null;
}

/** 高德对缺失字段返回空数组 `[]` 而非 null，需一并归一化为 null。 */
function readString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}
