/**
 * Captain 编排主循环。
 *
 * 每个阶段把 agent_task 行随状态机推进（queued→running→succeeded/partial/
 * failed），并经 append_squad_event 发布事件。阶段间通过 OrchestrationContext
 * 传递结构化产物；单阶段失败按矩阵降级（重试一次 → 降级继续 / 终止）。
 *
 * 数据库访问使用 service-role 客户端：任务行属于编排器内部状态，RLS 撤销了
 * 客户端 DML；service-role 只在服务端函数内使用，绝不回传客户端。
 */
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import { verifyCandidates } from './fact.ts';
import { parseCommandIntent } from './intent.ts';
import { readMemorySignals } from './memory.ts';
import { rankPlaces } from './recommend.ts';
import { searchAmapPlaces, requireAmapKey, type AmapQuery } from '../places-search/amap.ts';
import {
  OrchestrationError,
  type AgentRole,
  type OrchestrationContext,
  type PlaceCandidate,
} from './types.ts';

/** 阶段超时（multi-agent-arch.md 第 5 节）。 */
const PHASE_TIMEOUT_MS: Record<string, number> = {
  intent: 5_000,
  memory: 5_000,
  map: 15_000,
  fact: 10_000,
  recommend: 8_000,
  present: 5_000,
};

interface OrchestrationDeps {
  serviceClient: SupabaseClient;
  userId: string;
}

export async function runOrchestration(
  serviceClient: SupabaseClient,
  userId: string,
  sessionId: string,
  commandId: string,
  taskId: string,
): Promise<void> {
  const deps: OrchestrationDeps = { serviceClient, userId };

  const { data: commandRow } = await serviceClient
    .from('captain_commands')
    .select('raw_text, task_type, context, constraints_json')
    .eq('id', commandId)
    .single();
  if (!commandRow) {
    await failSession(deps, sessionId, taskId, 'command_missing', '指令不存在');
    return;
  }

  const ctx: OrchestrationContext = {
    sessionId,
    commandId,
    taskId,
    userId,
    rawText: String(commandRow['raw_text'] ?? ''),
    taskType: String(commandRow['task_type'] ?? 'discover_places'),
    constraints: (commandRow['constraints_json'] ?? {}) as Record<string, unknown>,
    intent: null,
    memoryNotes: [],
    candidates: [],
    verified: [],
    recommendations: [],
    routePath: null,
    degraded: [],
  };

  const viewport = extractViewport(commandRow['context']);
  const sessionClosed = await checkCancelled(deps, sessionId);
  if (sessionClosed) return;

  // 主任务进入执行态：submit 时创建的 result_coordinator 骨架任务。
  await deps.serviceClient.from('agent_tasks').update({
    status: 'running',
    started_at: new Date().toISOString(),
    user_summary: '队务官正在调度小队',
  }).eq('id', taskId);

  // ── Phase A（并行）：Intent + Memory ─────────────────────────────
  await Promise.all([
    runPhase(deps, ctx, 'intent_interpreter', 'intent', async () => {
      ctx.intent = parseCommandIntent(ctx.rawText, ctx.constraints, ctx.constraints);
      await progress(deps, ctx, ctx.taskId, 'intent.normalized', {
        city: ctx.intent.city,
        area: ctx.intent.area,
        mealPeriod: ctx.intent.mealPeriod,
        budgetPerPersonMinor: ctx.intent.budgetPerPersonMinor,
        avoid: ctx.intent.avoid,
      });
      return { summary: intentSummary(ctx.intent), complete: true };
    }, PHASE_TIMEOUT_MS.intent),
    runPhase(deps, ctx, 'preference_advisor', 'memory', async () => {
      const signals = await readMemorySignals(serviceClient, userId);
      ctx.memoryNotes = signals.favoriteNames.slice(0, 5);
      return {
        summary: signals.favoriteCount > 0
          ? `读取到 ${signals.favoriteCount} 条收藏偏好`
          : '暂无历史偏好，使用显式条件',
        complete: true,
      };
    }, PHASE_TIMEOUT_MS.memory),
  ]);
  if (await checkCancelled(deps, sessionId)) return;
  if (ctx.intent === null) {
    await failSession(deps, sessionId, taskId, 'intent_failed', '需求理解失败，无法继续');
    return;
  }

  // ── Phase B：Map 召回候选 ────────────────────────────────────────
  await runPhase(deps, ctx, 'map_explorer', 'map', async () => {
    const query = buildSearchQuery(ctx, viewport);
    const places = await searchAmapPlaces(query, requireAmapKey());
    ctx.candidates = places as PlaceCandidate[];
    if (ctx.candidates.length === 0) {
      return { summary: '当前区域没有找到候选地点', complete: false };
    }
    return { summary: `找到 ${ctx.candidates.length} 个候选地点`, complete: true };
  }, PHASE_TIMEOUT_MS.map);
  if (await checkCancelled(deps, sessionId)) return;

  if (ctx.candidates.length === 0) {
    await finishWithoutResults(deps, ctx);
    return;
  }

  // ── Phase C：Fact 核验 ───────────────────────────────────────────
  await runPhase(deps, ctx, 'fact_checker', 'fact', async () => {
    const signals = await readMemorySignals(serviceClient, userId);
    ctx.verified = verifyCandidates(ctx.candidates, signals);
    const usable = ctx.verified.filter((place) => place.latitude !== null).length;
    return {
      summary: `核验完成，${usable}/${ctx.verified.length} 个候选可用`,
      complete: usable > 0,
    };
  }, PHASE_TIMEOUT_MS.fact);
  if (await checkCancelled(deps, sessionId)) return;

  const usable = ctx.verified.filter((place) => place.latitude !== null);
  if (usable.length === 0) {
    await finishWithoutResults(deps, ctx);
    return;
  }

  // ── Phase D：Recommend 排序 ──────────────────────────────────────
  await runPhase(deps, ctx, 'recommendation_decider', 'recommend', async () => {
    const signals = await readMemorySignals(serviceClient, userId);
    const resultLimit = typeof ctx.constraints['resultLimit'] === 'number'
      ? Math.trunc(ctx.constraints['resultLimit'] as number)
      : 5;
    ctx.recommendations = rankPlaces(usable, ctx.intent!, signals, {
      centerLatitude: viewport?.latitude ?? null,
      centerLongitude: viewport?.longitude ?? null,
      resultLimit,
    });
    return { summary: `已生成 ${ctx.recommendations.length} 条推荐`, complete: true };
  }, PHASE_TIMEOUT_MS.recommend);
  if (await checkCancelled(deps, sessionId)) return;

  // ── Phase F：Present 汇总落库（E 阶段路线在本轮延后）────────────
  await runPhase(deps, ctx, 'result_coordinator', 'present', async () => {
    const { error } = await serviceClient.from('recommendation_sets').insert({
      session_id: sessionId,
      task_id: taskId,
      status: 'generated',
      items: ctx.recommendations,
    });
    if (error) {
      throw new OrchestrationError('present_write_failed', error.message);
    }
    return { summary: `已汇总 ${ctx.recommendations.length} 条推荐结果`, complete: true };
  }, PHASE_TIMEOUT_MS.present);

  // ── 会话收尾 ─────────────────────────────────────────────────────
  const partial = ctx.degraded.length > 0;
  await serviceClient.from('squad_sessions').update({
    status: partial ? 'partially_completed' : 'completed',
  }).eq('id', sessionId);
  await serviceClient.from('captain_commands').update({
    status: partial ? 'partially_completed' : 'completed',
  }).eq('id', commandId);
  await appendEvent(deps, sessionId, commandId, null, partial ? 'session.partially_completed' : 'session.completed', {
    summary: partial
      ? `部分完成：${ctx.degraded.join('；')}`
      : `小队任务完成，共 ${ctx.recommendations.length} 条推荐`,
    degraded: ctx.degraded,
  });
}

/** 执行单阶段：建任务行 → running → 事件 → 成功/失败收敛，含一次性重试。 */
async function runPhase(
  deps: OrchestrationDeps,
  ctx: OrchestrationContext,
  role: AgentRole,
  phaseName: string,
  work: () => Promise<{ summary: string; complete: boolean }>,
  timeoutMs: number,
): Promise<void> {
  const taskId = await createTask(deps, ctx.sessionId, ctx.commandId, role);
  const attempt = async (): Promise<boolean> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const { summary, complete } = await work();
      clearTimeout(timer);
      await deps.serviceClient.from('agent_tasks').update({
        status: complete ? 'succeeded' : 'partial',
        user_summary: summary,
        finished_at: new Date().toISOString(),
        progress: complete ? 100 : 60,
      }).eq('id', taskId);
      await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, complete ? 'task.succeeded' : 'task.partial', { summary, role });
      return true;
    } catch (error) {
      clearTimeout(timer);
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[${phaseName}] attempt failed:`, message);
      return false;
    }
  };

  await deps.serviceClient.from('agent_tasks').update({ status: 'running', started_at: new Date().toISOString() }).eq('id', taskId);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, 'task.started', { role, phase: phaseName });

  const firstOk = await attempt();
  if (firstOk) return;

  // 重试一次。
  await deps.serviceClient.from('agent_tasks').update({ status: 'retrying', retry_count: 1 }).eq('id', taskId);
  const secondOk = await attempt();
  if (secondOk) return;

  // 降级或终止。
  const fatal = phaseName === 'intent' || phaseName === 'map' || phaseName === 'recommend' || phaseName === 'present';
  await deps.serviceClient.from('agent_tasks').update({
    status: fatal ? 'failed' : 'partial',
    user_summary: fatal ? `${phaseName} 阶段失败` : `${phaseName} 阶段降级跳过`,
    error_code: `${phaseName}_failed`,
    finished_at: new Date().toISOString(),
  }).eq('id', taskId);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, fatal ? 'task.failed' : 'task.partial', {
    role,
    summary: fatal ? `${phaseName} 阶段失败` : `${phaseName} 阶段降级跳过`,
  });
  if (fatal) {
    ctx.degraded.push(`${phaseName} 失败`);
    await failSession(deps, ctx.sessionId, ctx.taskId, `${phaseName}_failed`, `${phaseName} 阶段执行失败`);
  } else {
    ctx.degraded.push(`${phaseName} 降级`);
  }
}

async function createTask(
  deps: OrchestrationDeps,
  sessionId: string,
  commandId: string,
  role: AgentRole,
): Promise<string> {
  const { data, error } = await deps.serviceClient.from('agent_tasks').insert({
    session_id: sessionId,
    command_id: commandId,
    role,
    status: 'queued',
  }).select('id').single();
  if (error || !data) {
    throw new OrchestrationError('task_create_failed', error?.message ?? 'task insert returned no id');
  }
  const id = String(data['id']);
  await appendEvent(deps, sessionId, commandId, id, 'task.created', { role });
  return id;
}

async function progress(
  deps: OrchestrationDeps,
  ctx: OrchestrationContext,
  taskId: string,
  eventType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  await deps.serviceClient.from('agent_tasks').update({ user_summary: '已解析结构化条件' }).eq('id', taskId);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, eventType, payload);
}

async function appendEvent(
  deps: OrchestrationDeps,
  sessionId: string | null,
  commandId: string | null,
  taskId: string | null,
  eventType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const { data, error } = await deps.serviceClient.rpc('append_squad_event', {
    p_session_id: sessionId,
    p_command_id: commandId,
    p_task_id: taskId,
    p_event_type: eventType,
    p_actor: 'orchestrator',
    p_payload: payload,
    p_visibility: 'captain',
  });
  if (error) {
    console.error('append_squad_event failed:', error.message);
  }
}

async function checkCancelled(deps: OrchestrationDeps, sessionId: string): Promise<boolean> {
  const { data } = await deps.serviceClient
    .from('squad_sessions')
    .select('status')
    .eq('id', sessionId)
    .single();
  return data?.['status'] === 'cancelled';
}

async function failSession(
  deps: OrchestrationDeps,
  sessionId: string,
  taskId: string,
  code: string,
  message: string,
): Promise<void> {
  await deps.serviceClient.from('agent_tasks').update({
    status: 'failed',
    error_code: code,
    user_summary: message,
    finished_at: new Date().toISOString(),
  }).eq('id', taskId);
  await deps.serviceClient.from('squad_sessions').update({ status: 'failed' }).eq('id', sessionId);
  await appendEvent(deps, sessionId, null, taskId, 'session.failed', { summary: message, code });
}

async function finishWithoutResults(deps: OrchestrationDeps, ctx: OrchestrationContext): Promise<void> {
  await deps.serviceClient.from('agent_tasks').update({
    status: 'succeeded',
    user_summary: '未找到符合条件的地点，任务完成但无推荐结果',
    finished_at: new Date().toISOString(),
  }).eq('id', ctx.taskId);
  await deps.serviceClient.from('squad_sessions').update({ status: 'completed' }).eq('id', ctx.sessionId);
  await deps.serviceClient.from('captain_commands').update({ status: 'completed' }).eq('id', ctx.commandId);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, null, 'session.completed', {
    summary: '未找到符合条件的地点。可能原因：条件过严、当前区域无数据或视野无效。',
    emptyResult: true,
  });
}

function buildSearchQuery(
  ctx: OrchestrationContext,
  viewport: { latitude: number; longitude: number } | null,
): AmapQuery {
  const keywords = ctx.intent?.keywords ?? '美食';
  if (viewport) {
    return {
      kind: 'around',
      longitude: viewport.longitude,
      latitude: viewport.latitude,
      radius: 5000,
      keywords,
      page: 1,
    };
  }
  return {
    kind: 'text',
    keywords,
    city: ctx.intent?.city ?? undefined,
    page: 1,
  };
}

function extractViewport(context: unknown): { latitude: number; longitude: number } | null {
  if (typeof context !== 'object' || context === null) return null;
  const viewport = (context as Record<string, unknown>)['mapViewport'];
  if (typeof viewport !== 'object' || viewport === null) return null;
  const center = (viewport as Record<string, unknown>)['center'];
  if (typeof center !== 'object' || center === null) return null;
  const latitude = (center as Record<string, unknown>)['latitude'];
  const longitude = (center as Record<string, unknown>)['longitude'];
  if (typeof latitude === 'number' && typeof longitude === 'number') {
    return { latitude, longitude };
  }
  return null;
}

function intentSummary(intent: NonNullable<OrchestrationContext['intent']>): string {
  const parts: string[] = [];
  if (intent.city) parts.push(`城市 ${intent.city}`);
  if (intent.area) parts.push(`区域 ${intent.area}`);
  if (intent.mealPeriod) parts.push(`时段 ${intent.mealPeriod}`);
  if (intent.budgetPerPersonMinor !== null) parts.push(`人均 ${intent.budgetPerPersonMinor / 100} 元`);
  if (intent.partySize !== null) parts.push(`${intent.partySize} 人`);
  if (intent.avoid.length > 0) parts.push(`忌口 ${intent.avoid.join('、')}`);
  if (intent.needRoute) parts.push('需要路线');
  return parts.length > 0 ? `已解析条件：${parts.join('，')}` : '已解析指令条件';
}
