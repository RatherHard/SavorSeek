/**
 * trip-route 的错误分类。
 *
 * code 与 places-search 保持同名同义：客户端已按这套 code 分支（见
 * trip_route_service.dart 的 reasonFrom），两个函数各起一套名字只会让
 * 客户端为同一种故障写两遍映射。
 */
export type TripRouteErrorCode =
  /** 请求体字段缺失或不合法（点数不足、经纬度越界等）。 */
  | 'invalid_request'
  /** 缺少或无效的用户 JWT。 */
  | 'unauthenticated'
  /** 服务端未配置高德 Web 服务 Key。属部署问题。 */
  | 'provider_key_missing'
  /** Key 存在但被高德拒绝（无效、过期、白名单不匹配）。 */
  | 'provider_key_rejected'
  /** 高德配额或频率超限。 */
  | 'provider_quota_exceeded'
  /** 高德不可用、超时或返回无法解析的响应。 */
  | 'provider_unavailable';

const STATUS_BY_CODE: Record<TripRouteErrorCode, number> = {
  invalid_request: 400,
  unauthenticated: 401,
  // 502 而非 500：故障源在上游供应商或其配置，而非本函数逻辑。
  provider_key_missing: 502,
  provider_key_rejected: 502,
  provider_quota_exceeded: 429,
  provider_unavailable: 502,
};

export class TripRouteError extends Error {
  constructor(
    readonly code: TripRouteErrorCode,
    message: string,
    /** 排障线索，只进服务端日志，不随响应下发。 */
    readonly detail?: string,
  ) {
    super(message);
    this.name = 'TripRouteError';
  }

  get status(): number {
    return STATUS_BY_CODE[this.code];
  }
}

export const jsonHeaders = {
  'Content-Type': 'application/json; charset=utf-8',
} as const;

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
} as const;

/**
 * 把错误渲染为响应。
 *
 * detail 只写日志不下发：它可能包含高德返回的原始信息，对用户无意义，且可能
 * 泄漏服务端配置细节。
 */
export function errorResponse(error: unknown): Response {
  const known = error instanceof TripRouteError ? error : new TripRouteError(
    'provider_unavailable',
    '路线服务暂时不可用，请稍后重试。',
    error instanceof Error ? error.message : String(error),
  );

  console.error(
    JSON.stringify({
      level: 'error',
      fn: 'trip-route',
      code: known.code,
      message: known.message,
      detail: known.detail,
    }),
  );

  return new Response(
    JSON.stringify({ error: { code: known.code, message: known.message } }),
    { status: known.status, headers: { ...corsHeaders, ...jsonHeaders } },
  );
}
