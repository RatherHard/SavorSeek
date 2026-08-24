/**
 * 高德 Web 服务 API 的路径规划客户端。
 *
 * 为什么走服务端代理而不是客户端 SDK：`amap_map 1.0.15` 只提供地图显示与覆盖物
 * （AMapWidget / Marker / Polyline），不含任何路径规划能力。路线因此必须请求
 * Web 服务 API，而该 API 的 Key 一旦打进 APK 就能被反编译提取、配额不可控，
 * 故与地点检索采取同一策略：Key 只留服务端。
 *
 * 错误码语义见官方文档（https://lbs.amap.com/api/webservice/guide/tools/info），
 * 分类与 places-search/amap.ts 保持一致。
 */
import { TripRouteError } from './errors.ts';

const AMAP_BASE = 'https://restapi.amap.com/v3/direction';

/** 请求超时。路径规划比 POI 检索重，给到 10s。 */
const TIMEOUT_MS = 10_000;

/** Key 或权限配置错误：重试无意义，必须改配置。 */
const CONFIG_ERROR_CODES = new Set([
  '10001', // INVALID_USER_KEY
  '10002', // SERVICE_NOT_AVAILABLE
  '10005', // INVALID_USER_IP
  '10006', // INVALID_USER_DOMAIN
  '10008', // INVALID_USER_SCODE
  '10009', // USERKEY_PLAT_NOMATCH
  '10012', // INSUFFICIENT_PRIVILEGES
  '10013', // USER_KEY_RECYCLED
  '10041', // NO_EFFECTIVE_INTERFACE
]);

/** 限流与配额类：短期内重试或次日恢复。 */
const QUOTA_ERROR_CODES = new Set([
  '10003', // DAILY_QUERY_OVER_LIMIT
  '10004', // ACCESS_TOO_FREQUENT
  '10010', // IP_QUERY_OVER_LIMIT
  '10014', // QPS_HAS_EXCEEDED_THE_LIMIT
  '10015', // GATEWAY_TIMEOUT
  '10019',
  '10020',
  '10021',
  '10044', // USER_DAILY_QUERY_OVER_LIMIT
  '40000', // QUOTA_PLAN_RUN_OUT
  '40002', // SERVICE_EXPIRED
]);

/** 支持的出行方式，对应 `trips.default_travel_mode`。 */
export type TravelMode = 'walking' | 'driving' | 'bicycling';

/** 坐标点。坐标系为 gcj02，与底图及 place_snapshot 一致。 */
export interface GeoPoint {
  latitude: number;
  longitude: number;
}

interface AmapResponse {
  status?: string;
  info?: string;
  infocode?: string;
  route?: unknown;
}

/** 读取 Key。缺失与占位值都视为未配置：占位值会让高德返回 10001，误导排障。 */
export function requireAmapKey(): string {
  const key = Deno.env.get('AMAP_WEB_SERVICE_KEY')?.trim();
  if (!key || key === 'REPLACE_ME') {
    throw new TripRouteError(
      'provider_key_missing',
      '服务端未配置路线规划所需的密钥，请联系管理员。',
      '环境变量 AMAP_WEB_SERVICE_KEY 未设置或仍为占位值',
    );
  }
  return key;
}

/**
 * 依次连接各点，返回沿真实路网的完整路径。
 *
 * 高德的 direction 接口一次只接受一组起终点，N 个节点需 N-1 次请求。在服务端
 * 串行合并而不是让客户端发 N-1 次：客户端逐段请求会暴露分段逻辑、放大失败面，
 * 且每段都要过一次鉴权。
 *
 * 任一段失败即整体失败：只画出一半的路线比退化成直线更容易误导用户。
 */
export async function resolveRoute(
  points: GeoPoint[],
  mode: TravelMode,
  key: string,
): Promise<GeoPoint[]> {
  const path: GeoPoint[] = [];

  for (let index = 0; index < points.length - 1; index++) {
    const segment = await fetchSegment(
      points[index],
      points[index + 1],
      mode,
      key,
    );
    // 相邻段的首尾是同一个点，去重避免折线上出现重复顶点。
    if (path.length > 0 && segment.length > 0) segment.shift();
    path.push(...segment);
  }

  return path;
}

async function fetchSegment(
  origin: GeoPoint,
  destination: GeoPoint,
  mode: TravelMode,
  key: string,
): Promise<GeoPoint[]> {
  const url = new URL(`${AMAP_BASE}/${mode}`);
  const params = url.searchParams;
  params.set('key', key);
  // 高德的 location 顺序是「经度,纬度」，与常见的 lat,lng 相反，写反会静默
  // 返回错误区域的结果而非报错。
  params.set('origin', `${origin.longitude},${origin.latitude}`);
  params.set('destination', `${destination.longitude},${destination.latitude}`);
  // 驾车策略 0 = 速度优先；步行与骑行接口忽略该参数。
  if (mode === 'driving') params.set('strategy', '0');

  const payload = await fetchAmap(url);
  assertAmapOk(payload);
  return parsePolyline(payload.route);
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
    throw new TripRouteError(
      'provider_unavailable',
      isTimeout ? '路线规划超时，请稍后重试。' : '暂时无法连接路线规划服务。',
      error instanceof Error ? error.message : String(error),
    );
  }

  if (!response.ok) {
    throw new TripRouteError(
      'provider_unavailable',
      '路线规划服务返回异常，请稍后重试。',
      `HTTP ${response.status}`,
    );
  }

  try {
    return await response.json() as AmapResponse;
  } catch (error) {
    throw new TripRouteError(
      'provider_unavailable',
      '路线规划服务返回了无法解析的内容。',
      error instanceof Error ? error.message : String(error),
    );
  }
}

/**
 * 校验高德的业务状态。
 *
 * HTTP 200 不代表成功：高德把业务失败也放在 200 响应里，靠 status 字段区分
 * （"1" 成功、"0" 失败）。只看 HTTP 状态码会把「Key 无效」当成「无可用路线」。
 */
function assertAmapOk(payload: AmapResponse): void {
  if (payload.status === '1') return;

  const infocode = payload.infocode ?? '';
  const detail = `infocode=${infocode} info=${payload.info ?? ''}`;

  if (CONFIG_ERROR_CODES.has(infocode)) {
    throw new TripRouteError(
      'provider_key_rejected',
      '路线规划服务的密钥配置有误，请联系管理员。',
      detail,
    );
  }
  if (QUOTA_ERROR_CODES.has(infocode)) {
    throw new TripRouteError(
      'provider_quota_exceeded',
      '路线规划请求过于频繁，请稍后重试。',
      detail,
    );
  }
  throw new TripRouteError(
    'provider_unavailable',
    '路线规划服务暂时不可用，请稍后重试。',
    detail,
  );
}

/**
 * 从响应里抽出折线顶点。
 *
 * 高德把路径拆成 paths[].steps[].polyline，每个 polyline 是
 * "116.481,39.99;116.482,39.99" 形式的分号分隔串。只取第一条方案：用户要的是
 * 一条能看的路线，多方案对比不在小地图的职责内。
 */
function parsePolyline(route: unknown): GeoPoint[] {
  if (typeof route !== 'object' || route === null) return [];
  const paths = (route as Record<string, unknown>).paths;
  if (!Array.isArray(paths) || paths.length === 0) return [];

  const first = paths[0];
  if (typeof first !== 'object' || first === null) return [];
  const steps = (first as Record<string, unknown>).steps;
  if (!Array.isArray(steps)) return [];

  const points: GeoPoint[] = [];
  for (const step of steps) {
    if (typeof step !== 'object' || step === null) continue;
    const polyline = (step as Record<string, unknown>).polyline;
    if (typeof polyline !== 'string') continue;
    for (const pair of polyline.split(';')) {
      const point = parsePoint(pair);
      if (point) points.push(point);
    }
  }
  return points;
}

/** 单个 "经度,纬度" 对。越界或非数字一律丢弃，避免把视野拉到世界另一端。 */
function parsePoint(pair: string): GeoPoint | null {
  const [lngText, latText] = pair.split(',');
  const longitude = Number(lngText);
  const latitude = Number(latText);
  if (!Number.isFinite(longitude) || !Number.isFinite(latitude)) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  return { latitude, longitude };
}
