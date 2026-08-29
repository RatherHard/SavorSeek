/**
 * agent：Captain 总控入口。
 *
 * 命令面（对接设计 8.2 节）：
 *   submit_command  提交队长指令 → 建骨架 → 异步执行 Phase A→F 编排
 *   cancel_session  取消小队会话
 *   get_session     读取会话全量投影（快照恢复）
 *   list_events     增量拉取事件（断线补齐）
 *
 * 编排在 EdgeRuntime.waitUntil 中异步执行：HTTP 响应先返回任务骨架，
 * 阶段进度经 squad_events（Realtime publication 已配置）推给客户端。
 */
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import { runOrchestration } from './orchestrator.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TASK_TYPES = new Set([
  'discover_places',
  'compare_recommendations',
  'plan_route',
  'replan_trip',
  'general_exploration',
]);

type RpcResult = { data: unknown; error: { message: string } | null };

class RpcError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message?: string) {
    super(message ?? code);
    this.status = status;
    this.code = code;
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_RE.test(value);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function requireUuid(value: unknown, code: string): void {
  if (!isUuid(value)) throw new RpcError(400, code);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const authorization = req.headers.get('Authorization');
  if (!authorization?.toLowerCase().startsWith('bearer ')) {
    return json({ error: 'authentication_required' }, 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !supabaseAnonKey || !serviceKey) {
    return json({ error: 'function_not_configured' }, 500);
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'authentication_required' }, 401);
  const userId = userData.user.id;

  const serviceClient = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch (_error) {
    return json({ error: 'invalid_json' }, 400);
  }
  if (!isObject(body) || typeof body['command'] !== 'string') {
    return json({ error: 'missing_command' }, 400);
  }

  try {
    return await handle(userClient, serviceClient, userId, body);
  } catch (error) {
    if (error instanceof RpcError) {
      return json({ error: error.code, detail: error.message }, error.status);
    }
    console.error('unhandled error:', error instanceof Error ? error.message : error);
    return json({ error: 'internal_error' }, 500);
  }
});

async function handle(
  userClient: SupabaseClient,
  serviceClient: SupabaseClient,
  userId: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const command = body['command'];

  if (command === 'submit_command') {
    return handleSubmitCommand(userClient, serviceClient, userId, body);
  }
  if (command === 'cancel_session') {
    if (!isUuid(body['sessionId'])) throw new RpcError(400, 'invalid_session_id');
    const { data, error } = await userClient.rpc('cancel_squad_session', {
      p_session_id: body['sessionId'],
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'retry_task') {
    requireUuid(body['taskId'], 'invalid_task_id');
    const { data, error } = await userClient.rpc('retry_agent_task', { p_task_id: body['taskId'] }) as RpcResult;
    if (error) throw rpcToHttp(error);
    const retry = data as Record<string, unknown>;
    EdgeRuntime.waitUntil(runOrchestration(
      serviceClient,
      userId,
      String(retry['sessionId']),
      String(retry['commandId']),
      String(retry['taskId']),
    ));
    return json({ ok: true, ...retry });
  }
  if (command === 'select_recommendation') {
    requireUuid(body['sessionId'], 'invalid_session_id');
    requireUuid(body['recommendationSetId'], 'invalid_recommendation_set_id');
    const names = body['placeNames'];
    if (!Array.isArray(names) || names.length === 0 || !names.every((n) => typeof n === 'string' && n.length > 0 && n.length <= 120)) {
      throw new RpcError(400, 'invalid_place_names');
    }
    const { data, error } = await userClient.rpc('select_recommendation', {
      p_session_id: body['sessionId'],
      p_recommendation_set_id: body['recommendationSetId'],
      p_place_names: names,
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'reject_recommendation') {
    requireUuid(body['sessionId'], 'invalid_session_id');
    requireUuid(body['recommendationSetId'], 'invalid_recommendation_set_id');
    const { data, error } = await userClient.rpc('reject_recommendation', {
      p_session_id: body['sessionId'],
      p_recommendation_set_id: body['recommendationSetId'],
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'compare_recommendations') {
    requireUuid(body['sessionId'], 'invalid_session_id');
    const names = body['placeNames'];
    if (!Array.isArray(names) || names.length < 2 || names.length > 5 || !names.every((name) => typeof name === 'string')) {
      throw new RpcError(400, 'invalid_place_names');
    }
    const { data, error } = await userClient.rpc('get_squad_session_projection', { p_session_id: body['sessionId'] }) as RpcResult;
    if (error) throw rpcToHttp(error);
    const projection = data as Record<string, unknown>;
    const sets = Array.isArray(projection['recommendations']) ? projection['recommendations'] : [];
    return json({ ok: true, comparison: compareNamedItems(sets, names as string[]) });
  }
  if (command === 'save_place') {
    requireUuid(body['placeId'], 'invalid_place_id');
    requireUuid(body['idempotencyKey'], 'invalid_idempotency_key');
    const { data, error } = await userClient.rpc(body['saved'] == false ? 'remove_favorite' : 'add_favorite', {
      p_place_id: body['placeId'], p_idempotency_key: body['idempotencyKey'],
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'modify_trip_item') {
    requireUuid(body['tripId'], 'invalid_trip_id');
    requireUuid(body['tripItemId'], 'invalid_trip_item_id');
    requireUuid(body['idempotencyKey'], 'invalid_idempotency_key');
    const revision = body['expectedRevision'];
    const localDate = body['localDate'];
    const startAt = body['plannedStartAt'];
    const endAt = body['plannedEndAt'];
    const timeSlot = body['timeSlot'];
    if (typeof revision !== 'number' || !Number.isInteger(revision) || revision < 1 ||
        typeof localDate !== 'string' || typeof startAt !== 'string' || typeof endAt !== 'string' || typeof timeSlot !== 'string') {
      throw new RpcError(400, 'invalid_trip_item_change');
    }
    const { data, error } = await userClient.rpc('reschedule_trip_item_on_date', {
      p_trip_id: body['tripId'], p_expected_revision: revision, p_idempotency_key: body['idempotencyKey'],
      p_trip_item_id: body['tripItemId'], p_local_date: localDate,
      p_planned_start_at: startAt, p_planned_end_at: endAt, p_time_slot: timeSlot,
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'submit_recommendation_feedback') {
    requireUuid(body['sessionId'], 'invalid_session_id');
    requireUuid(body['recommendationSetId'], 'invalid_recommendation_set_id');
    const placeName = body['placeName'];
    const feedback = body['feedback'];
    if (typeof placeName !== 'string' || placeName.trim().length === 0 || placeName.length > 120) {
      throw new RpcError(400, 'invalid_place_name');
    }
    if (typeof feedback !== 'string' || !['liked', 'disliked', 'inaccurate'].includes(feedback)) {
      throw new RpcError(400, 'invalid_feedback');
    }
    const { data, error } = await userClient.rpc('submit_recommendation_feedback', {
      p_session_id: body['sessionId'],
      p_recommendation_set_id: body['recommendationSetId'],
      p_place_name: placeName,
      p_feedback: feedback,
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'memory_proposal_decision') {
    requireUuid(body['proposalId'], 'invalid_proposal_id');
    const decision = body['decision'];
    if (typeof decision !== 'string' || !['accept', 'reject', 'edit'].includes(decision)) {
      throw new RpcError(400, 'invalid_decision');
    }
    if (decision === 'edit' && (!isObject(body['editedValue']))) {
      throw new RpcError(400, 'invalid_edited_value');
    }
    const { data, error } = await userClient.rpc('resolve_memory_proposal', {
      p_proposal_id: body['proposalId'],
      p_decision: decision,
      p_edited_value: decision === 'edit' ? body['editedValue'] : null,
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'resolve_decision_checkpoint') {
    requireUuid(body['checkpointId'], 'invalid_checkpoint_id');
    const optionId = body['selectedOptionId'];
    if (typeof optionId !== 'string' || optionId.trim().length === 0 || optionId.length > 64) {
      throw new RpcError(400, 'invalid_option_id');
    }
    const { data, error } = await userClient.rpc('resolve_decision_checkpoint', {
      p_checkpoint_id: body['checkpointId'],
      p_selected_option_id: optionId,
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    if (optionId === 'apply') {
      const expectedRevision = body['expectedRevision'];
      const idempotencyKey = body['idempotencyKey'];
      requireUuid(idempotencyKey, 'invalid_idempotency_key');
      if (typeof expectedRevision !== 'number' || !Number.isInteger(expectedRevision) || expectedRevision < 1) {
        throw new RpcError(400, 'invalid_expected_revision');
      }
      const checkpoint = await userClient.from('decision_checkpoints')
        .select('affected_resource_refs')
        .eq('id', body['checkpointId'])
        .single();
      const refs = checkpoint.data?.['affected_resource_refs'];
      const draftId = Array.isArray(refs) && typeof refs[1] === 'string' ? refs[1] : null;
      requireUuid(draftId, 'invalid_draft_reference');
      const applied = await userClient.rpc('apply_trip_draft', {
        p_draft_id: draftId,
        p_expected_revision: expectedRevision,
        p_idempotency_key: idempotencyKey,
      }) as RpcResult;
      if (applied.error) throw rpcToHttp(applied.error);
      return json({ ok: true, ...(data as Record<string, unknown>), applied: applied.data });
    }
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'apply_trip_draft') {
    requireUuid(body['draftId'], 'invalid_draft_id');
    requireUuid(body['idempotencyKey'], 'invalid_idempotency_key');
    const expectedRevision = body['expectedRevision'];
    if (typeof expectedRevision !== 'number' || !Number.isInteger(expectedRevision) || expectedRevision < 1) {
      throw new RpcError(400, 'invalid_expected_revision');
    }
    const { data, error } = await userClient.rpc('apply_trip_draft', {
      p_draft_id: body['draftId'],
      p_expected_revision: expectedRevision,
      p_idempotency_key: body['idempotencyKey'],
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }
  if (command === 'get_session') {
    if (!isUuid(body['sessionId'])) throw new RpcError(400, 'invalid_session_id');
    const { data, error } = await userClient.rpc('get_squad_session_projection', {
      p_session_id: body['sessionId'],
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, projection: data });
  }
  if (command === 'list_events') {
    if (!isUuid(body['sessionId'])) throw new RpcError(400, 'invalid_session_id');
    const afterSequence = body['afterSequence'] ?? null;
    const limit = body['limit'] ?? 100;
    if (afterSequence !== null && (typeof afterSequence !== 'number' || !Number.isInteger(afterSequence) || afterSequence < 0)) {
      throw new RpcError(400, 'invalid_after_sequence');
    }
    if (typeof limit !== 'number' || !Number.isInteger(limit) || limit < 1 || limit > 500) {
      throw new RpcError(400, 'invalid_limit');
    }
    const { data, error } = await userClient.rpc('list_squad_events', {
      p_session_id: body['sessionId'],
      p_after_sequence: afterSequence,
      p_limit: limit,
    }) as RpcResult;
    if (error) throw rpcToHttp(error);
    return json({ ok: true, ...(data as Record<string, unknown>) });
  }

  throw new RpcError(400, 'unknown_command');
}

async function handleSubmitCommand(
  userClient: SupabaseClient,
  serviceClient: SupabaseClient,
  userId: string,
  body: Record<string, unknown>,
): Promise<Response> {
  const clientRequestId = body['clientRequestId'];
  const title = body['title'];
  const goal = body['goal'];
  const rawText = body['rawText'];
  const taskType = body['taskType'];
  const context = body['context'];
  const constraints = body['constraints'];

  if (!isUuid(clientRequestId)) throw new RpcError(400, 'invalid_client_request_id');
  if (typeof title !== 'string' || title.trim().length === 0 || title.length > 120) {
    throw new RpcError(400, 'invalid_title');
  }
  if (typeof goal !== 'string' || goal.trim().length === 0 || goal.length > 2000) {
    throw new RpcError(400, 'invalid_goal');
  }
  if (typeof rawText !== 'string' || rawText.trim().length === 0 || rawText.length > 2000) {
    throw new RpcError(400, 'invalid_raw_text');
  }
  if (typeof taskType !== 'string' || !TASK_TYPES.has(taskType)) {
    throw new RpcError(400, 'invalid_task_type');
  }
  if (context !== undefined && !isObject(context)) throw new RpcError(400, 'invalid_context');
  if (constraints !== undefined && !isObject(constraints)) throw new RpcError(400, 'invalid_constraints');

  const { data, error } = await userClient.rpc('submit_captain_command', {
    p_client_request_id: clientRequestId,
    p_title: title,
    p_goal: goal,
    p_raw_text: rawText,
    p_task_type: taskType,
    p_context: context ?? {},
    p_constraints: constraints ?? {},
    p_memory_policy: typeof body['memoryPolicy'] === 'string' ? body['memoryPolicy'] : 'propose_only',
    p_locale: typeof body['locale'] === 'string' ? body['locale'] : 'zh-CN',
    p_client_version: typeof body['clientVersion'] === 'string' ? body['clientVersion'] : null,
  }) as RpcResult;
  if (error) {
    const conflict = /reused with different/.test(error.message);
    throw new RpcError(conflict ? 409 : 400, 'command_rejected', error.message);
  }

  const skeleton = data as Record<string, unknown>;

  // 幂等重放：命中已有指令时不再编排。
  if (skeleton['status'] !== 'accepted') {
    return json({ ok: true, ...skeleton });
  }

  // 由 Edge Runtime 托管异步执行生命周期；普通 fire-and-forget 可能在响应后被终止。
  const sessionId = String(skeleton['sessionId']);
  const commandId = String(skeleton['commandId']);
  const taskId = String(skeleton['taskId']);
  EdgeRuntime.waitUntil(runOrchestration(serviceClient, userId, sessionId, commandId, taskId));

  return json({ ok: true, ...skeleton });
}

function rpcToHttp(error: { message: string }): RpcError {
  const message = error.message;
  if (/session not found/.test(message)) return new RpcError(404, 'session_not_found', message);
  if (/not found/.test(message)) return new RpcError(404, 'resource_not_found', message);
  if (/terminal status/.test(message)) return new RpcError(409, 'session_terminal', message);
  if (/revision conflict/.test(message)) return new RpcError(409, 'trip_revision_conflict', message);
  if (/already (resolved|resolved|applied|selectable|rejectable)/.test(message)) return new RpcError(409, 'already_resolved', message);
  if (/reused with different/.test(message)) return new RpcError(409, 'idempotency_conflict', message);
  return new RpcError(400, 'rpc_rejected', message);
}

function compareNamedItems(sets: unknown[], names: string[]): unknown[] {
  const items: unknown[] = [];
  for (const set of sets) {
    if (!isObject(set) || !Array.isArray(set['items'])) continue;
    for (const item of set['items']) {
      if (isObject(item) && typeof item['name'] === 'string' && names.includes(item['name'])) items.push(item);
    }
  }
  return items;
}
