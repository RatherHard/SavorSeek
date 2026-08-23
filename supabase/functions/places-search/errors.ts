/**
 * 地点检索的错误分类。
 *
 * 设计文档 §12 明确要求空结果必须可区分，不能一律显示「暂未找到」。因此这里
 * 把「查得到但没有」与「查不了」拆成互斥的 code，由客户端各自给出不同文案与
 * 不同的下一步动作（重试 / 换条件 / 提示配置缺失）。
 *
 * 客户端依赖 code 而非 message 做分支：message 面向用户可随时改写，code 是契约。
 */
export type PlacesSearchErrorCode =
  /** 请求体字段缺失或不合法（关键词为空、经纬度越界、半径超范围等）。 */
  | 'invalid_request'
  /** 缺少或无效的用户 JWT。 */
  | 'unauthenticated'
  /** 服务端未配置高德 Web 服务 Key。属部署问题，不是用户输入问题。 */
  | 'provider_key_missing'
  /** Key 存在但被高德拒绝（无效、过期、域名/IP 白名单不匹配）。 */
  | 'provider_key_rejected'
  /** 高德配额或频率超限。 */
  | 'provider_quota_exceeded'
  /** 高德不可用、超时或返回无法解析的响应。 */
  | 'provider_unavailable'
  /** 数据库读写失败。 */
  | 'storage_failure';

/** 各错误码对应的 HTTP 状态码。 */
const STATUS_BY_CODE: Record<PlacesSearchErrorCode, number> = {
  invalid_request: 400,
  unauthenticated: 401,
  // 502 而非 500：故障源在上游供应商或其配置，而非本函数逻辑。
  provider_key_missing: 502,
  provider_key_rejected: 502,
  provider_quota_exceeded: 429,
  provider_unavailable: 502,
  storage_failure: 500,
};

export class PlacesSearchError extends Error {
  constructor(
    readonly code: PlacesSearchErrorCode,
    message: string,
    /** 排障线索，只进服务端日志，不随响应下发。 */
    readonly detail?: string,
  ) {
    super(message);
    this.name = 'PlacesSearchError';
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
  const known = error instanceof PlacesSearchError
    ? error
    : new PlacesSearchError(
      'storage_failure',
      '地点检索暂时不可用，请稍后重试。',
      error instanceof Error ? error.message : String(error),
    );

  console.error(
    JSON.stringify({
      level: 'error',
      fn: 'places-search',
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
