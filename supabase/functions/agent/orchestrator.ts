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
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import { verifyCandidates } from './fact.ts';
import { parseCommandIntent } from './intent.ts';
import { readMemorySignals } from './memory.ts';
import { rankPlaces } from './recommend.ts';
import { planRoute, toTripDraftItems } from './route.ts';
import { searchAmapPlaces, requireAmapKey, type AmapQuery } from '../places-search/amap.ts';
import { resolveRoute, type GeoPoint, type TravelMode } from '../trip-route/amap.ts';
import {
  OrchestrationError,
  type AgentRole,
  type OrchestrationContext,
  type PlaceCandidate,
  type PlaceSnapshot,
} from './types.ts';

/** 阶段超时（multi-agent-arch.md 第 5 节）。 */
const PHASE_TIMEOUT_MS: Record<string, number> = {
  intent: 5_000,
  memory: 5_000,
  map: 15_000,
  fact: 10_000,
  recommend: 8_000,
  route: 15_000,
  present: 5_000,
};

interface OrchestrationDeps {
  serviceClient: SupabaseClient;
  userId: string;
  planId: string;
}

interface PhaseResult {
  summary: string;
  complete: boolean;
  artifact?: {
    type: string;
    payload: Record<string, unknown>;
    confidence?: number | null;
  };
}

interface PhaseOutcome {
  status: 'succeeded' | 'partial' | 'failed' | 'timed_out';
  fatal: boolean;
  taskId: string;
  errorCode?: string;
}

type PhaseWork = (signal: AbortSignal, phaseTaskId: string) => Promise<PhaseResult>;

class PhaseTimeoutError extends Error {
  constructor() {
    super('phase timeout');
    this.name = 'PhaseTimeoutError';
  }
}

export async function runOrchestration(
  serviceClient: SupabaseClient,
  userId: string,
  sessionId: string,
  commandId: string,
  taskId: string,
): Promise<void> {
  try {
    await runOrchestrationInternal(serviceClient, userId, sessionId, commandId, taskId);
  } catch (error) {
    console.error('orchestration failed:', error instanceof Error ? error.message : String(error));
    await finalizeTopLevelFailure(
      { serviceClient, userId, planId: '' },
      sessionId,
      commandId,
      taskId,
    );
  }
}

async function runOrchestrationInternal(
  serviceClient: SupabaseClient,
  userId: string,
  sessionId: string,
  commandId: string,
  taskId: string,
): Promise<void> {
  const deps: OrchestrationDeps = { serviceClient, userId, planId: '' };

  const { data: commandRow } = await serviceClient
    .from('captain_commands')
    .select('raw_text, task_type, context, constraints_json, memory_policy')
    .eq('id', commandId)
    .single();
  if (!commandRow) {
    await failSession(deps, sessionId, commandId, taskId, 'command_missing', '指令不存在');
    return;
  }
  const { data: planRow } = await serviceClient
    .from('agent_plans')
    .select('id')
    .eq('command_id', commandId)
    .eq('session_id', sessionId)
    .single();
  if (!planRow) {
    await failSession(deps, sessionId, commandId, taskId, 'plan_missing', '任务计划不存在');
    return;
  }
  deps.planId = String(planRow['id']);

  const ctx: OrchestrationContext = {
    sessionId,
    commandId,
    planId: deps.planId,
    taskId,
    userId,
    rawText: String(commandRow['raw_text'] ?? ''),
    taskType: String(commandRow['task_type'] ?? 'discover_places'),
    context: (commandRow['context'] ?? {}) as Record<string, unknown>,
    constraints: (commandRow['constraints_json'] ?? {}) as Record<string, unknown>,
    memoryPolicy: commandRow['memory_policy'] === 'disabled' || commandRow['memory_policy'] === 'read_only'
      ? commandRow['memory_policy']
      : 'propose_only',
    intent: null,
    memoryNotes: [],
    candidates: [],
    verified: [],
    recommendations: [],
    routePath: null,
    tripDraftId: null,
    pendingDecision: false,
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
    runPhase(deps, ctx, 'intent_interpreter', 'intent', async (_signal, phaseTaskId) => {
      ctx.intent = parseCommandIntent(ctx.rawText, ctx.context, ctx.constraints);
      await progress(deps, ctx, phaseTaskId, 'intent.normalized', {
        city: ctx.intent.city,
        area: ctx.intent.area,
        mealPeriod: ctx.intent.mealPeriod,
        budgetPerPersonMinor: ctx.intent.budgetPerPersonMinor,
        avoid: ctx.intent.avoid,
      });
      return { summary: intentSummary(ctx.intent), complete: true, artifact: { type: 'intent', payload: { intent: ctx.intent }, confidence: 1 } };
    }, PHASE_TIMEOUT_MS.intent),
    runPhase(deps, ctx, 'preference_advisor', 'memory', async (_signal, _phaseTaskId) => {
      const signals = await readMemorySignals(serviceClient, userId);
      ctx.memoryNotes = signals.favoriteNames.slice(0, 5);
      return {
        summary: signals.favoriteCount > 0
          ? `读取到 ${signals.favoriteCount} 条收藏偏好`
          : '暂无历史偏好，使用显式条件',
        complete: true,
        artifact: { type: 'memory_context', payload: { favoriteCount: signals.favoriteCount, favoriteNames: signals.favoriteNames } },
      };
    }, PHASE_TIMEOUT_MS.memory),
  ]);
  if (await checkCancelled(deps, sessionId)) return;
  if (ctx.intent === null) {
    await failSession(deps, sessionId, commandId, taskId, 'intent_failed', '需求理解失败，无法继续');
    return;
  }

  // ── Phase B：Map 召回候选 ────────────────────────────────────────
  const mapOutcome = await runPhase(deps, ctx, 'map_explorer', 'map', async (signal, phaseTaskId) => {
    const query = buildSearchQuery(ctx, viewport);
    await updatePhaseProgress(deps, ctx, phaseTaskId, 25, '正在检索地图地点');
    const places = await searchAmapPlaces(query, requireAmapKey(), signal);
    if (signal.aborted) throw new PhaseTimeoutError();
    ctx.candidates = places as PlaceCandidate[];
    await updatePhaseProgress(deps, ctx, phaseTaskId, 80, '地点检索完成');
    if (ctx.candidates.length === 0) {
      return { summary: '当前区域没有找到候选地点', complete: false };
    }
    return {
      summary: `找到 ${ctx.candidates.length} 个候选地点`,
      complete: true,
      artifact: {
        type: 'place_candidates',
        payload: { candidates: ctx.candidates },
      },
    };
  }, PHASE_TIMEOUT_MS.map);
  if (mapOutcome.fatal || mapOutcome.status === 'timed_out') return;
  if (await checkCancelled(deps, sessionId)) return;

  if (ctx.candidates.length === 0) {
    await finishWithoutResults(deps, ctx);
    return;
  }

  // ── Phase C：Fact 核验 ───────────────────────────────────────────
  await runPhase(deps, ctx, 'fact_checker', 'fact', async (_signal, _phaseTaskId) => {
    const signals = await readMemorySignals(serviceClient, userId);
    ctx.verified = verifyCandidates(ctx.candidates, signals);
    const usable = ctx.verified.filter((place) => place.latitude !== null).length;
    return {
      summary: `核验完成，${usable}/${ctx.verified.length} 个候选可用`,
      complete: usable > 0,
      artifact: { type: 'fact_check', payload: { places: ctx.verified } },
    };
  }, PHASE_TIMEOUT_MS.fact);
  if (await checkCancelled(deps, sessionId)) return;

  const usable = ctx.verified.filter((place) => place.latitude !== null);
  if (usable.length === 0) {
    await finishWithoutResults(deps, ctx);
    return;
  }

  // ── Phase D：Recommend 排序 ──────────────────────────────────────
  const recommendOutcome = await runPhase(deps, ctx, 'recommendation_decider', 'recommend', async (_signal, _phaseTaskId) => {
    const signals = await readMemorySignals(serviceClient, userId);
    const resultLimit = typeof ctx.constraints['resultLimit'] === 'number'
      ? Math.trunc(ctx.constraints['resultLimit'] as number)
      : 5;
    ctx.recommendations = rankPlaces(usable, ctx.intent!, signals, {
      centerLatitude: viewport?.latitude ?? null,
      centerLongitude: viewport?.longitude ?? null,
      resultLimit,
    });
    return { summary: `已生成 ${ctx.recommendations.length} 条推荐`, complete: true, artifact: { type: 'recommendation_set', payload: { items: ctx.recommendations } } };
  }, PHASE_TIMEOUT_MS.recommend);
  if (recommendOutcome.fatal || recommendOutcome.status === 'timed_out') return;
  if (await checkCancelled(deps, sessionId)) return;

  // ── Phase E（可选）：Route 生成行程草案 ─────────────────────────
  const wantRoute = ctx.intent!.needRoute ||
    ctx.taskType === 'plan_route' ||
    ctx.taskType === 'replan_trip';
  if (wantRoute) {
    await runPhase(deps, ctx, 'route_planner', 'route', async (signal, phaseTaskId) => {
      const route = planRoute(usable, ctx.recommendations, {
        startDate: nextDinnerDate(),
        startHour: 18,
        maxStops: 5,
      });
      if (route.stops.length === 0) {
        return { summary: route.warnings.join('；'), complete: false };
      }
      const tripContextTripId = (ctx.context['tripId'] as string | undefined) ?? null;
      if (!tripContextTripId) {
        // 无关联行程：路线阶段降级为仅展示顺序（不写草案）。
        ctx.degraded.push('未关联行程，路线草案未落库');
        await appendEvent(deps, ctx.sessionId, ctx.commandId, null, 'trip.draft.created', {
          stops: route.stops.length,
          warnings: route.warnings,
          persisted: false,
        });
        return { summary: `已排出 ${route.stops.length} 站顺序（未关联行程，未落草案）`, complete: false };
      }
      const { data: tripRow, error: tripError } = await deps.serviceClient
        .from('trips')
        .select('start_date, revision, timezone, default_travel_mode')
        .eq('id', tripContextTripId)
        .eq('user_id', ctx.userId)
        .single();
      if (tripError || !tripRow) throw new OrchestrationError('trip_context_missing', '目标行程不存在');
      const targetDate = typeof tripRow['start_date'] === 'string' ? tripRow['start_date'] : nextDinnerDate();
      const plannedRoute = planRoute(usable, ctx.recommendations, {
        startDate: targetDate,
        startHour: 18,
        maxStops: 5,
        timezone: typeof tripRow['timezone'] === 'string' ? tripRow['timezone'] : 'UTC',
      });
      const routePoints: GeoPoint[] = plannedRoute.stops
        .map((stop) => stop.placeSnapshot)
        .filter((snapshot): snapshot is Record<string, unknown> => snapshot !== null)
        .flatMap((snapshot) => {
          const latitude = snapshot['latitude'];
          const longitude = snapshot['longitude'];
          return typeof latitude === 'number' && typeof longitude === 'number'
            ? [{ latitude, longitude }]
            : [];
        });
      let routePath: GeoPoint[] = [];
      try {
        const mode = tripRow['default_travel_mode'] === 'driving' ? 'driving' :
          tripRow['default_travel_mode'] === 'cycling' ? 'bicycling' : 'walking';
        routePath = await resolveRoute(routePoints, mode as TravelMode, requireAmapKey(), signal);
      } catch (error) {
        if (signal.aborted) throw new PhaseTimeoutError();
        plannedRoute.warnings.push('路线服务不可用，当前仅保留地点顺序和估算时间');
      }
      const placeIds = await persistPlaces(deps, usable);
      const { data: draftRow, error } = await deps.serviceClient.from('trip_drafts').insert({
        trip_id: tripContextTripId,
        session_id: ctx.sessionId,
        source_task_id: phaseTaskId,
        base_revision: typeof ctx.context['tripRevision'] === 'number'
          ? Math.trunc(ctx.context['tripRevision'] as number)
          : Number(tripRow['revision'] ?? 1),
        status: 'proposed',
        items: toTripDraftItems(plannedRoute.stops, ctx.recommendations, new Map(
          [...placeIds].map(([providerId, row]) => [providerId, String(row['id'])]),
        )),
        route_segments: routePath,
        warnings: plannedRoute.warnings,
        requires_captain_approval: true,
      }).select('id').single();
      if (error) {
        throw new OrchestrationError('route_write_failed', error.message);
      }
      ctx.tripDraftId = String((draftRow as Record<string, unknown>)['id']);
      const { data: checkpoint, error: checkpointError } = await deps.serviceClient
        .from('decision_checkpoints')
        .insert({
          session_id: ctx.sessionId,
          task_id: phaseTaskId,
          kind: 'apply_trip_draft',
          question: '路线草案需要更新当前行程，是否应用？',
          options: [
            { id: 'apply', label: '应用草案', impact: '更新当前行程版本' },
            { id: 'keep_locked', label: '保留现有安排', impact: '仅查看冲突' },
            { id: 'cancel', label: '取消本次调整', impact: '不修改行程' },
          ],
          affected_resource_refs: [tripContextTripId, ctx.tripDraftId],
          status: 'pending',
        })
        .select('id')
        .single();
      if (checkpointError) throw new OrchestrationError('checkpoint_write_failed', checkpointError.message);
      ctx.pendingDecision = true;
      await appendEvent(deps, ctx.sessionId, ctx.commandId, null, 'trip.draft.created', {
        draftId: ctx.tripDraftId,
        stops: plannedRoute.stops.length,
        warnings: plannedRoute.warnings,
      });
      await appendEvent(deps, ctx.sessionId, ctx.commandId, null, 'decision.required', {
        checkpointId: (checkpoint as Record<string, unknown>)['id'],
        draftId: ctx.tripDraftId,
      });
      return { summary: `已生成 ${plannedRoute.stops.length} 站路线草案，等待队长确认`, complete: true, artifact: { type: 'trip_draft', payload: { draftId: ctx.tripDraftId, stops: plannedRoute.stops } } };
    }, PHASE_TIMEOUT_MS.route);
    if (await checkCancelled(deps, sessionId)) return;
  }

  // ── Phase F：Present 汇总落库 ────────────────────────────────────
  const presentOutcome = await runPhase(deps, ctx, 'result_coordinator', 'present', async (_signal, _phaseTaskId) => {
    const placeIds = await persistPlaces(deps, usable);
    ctx.recommendations = ctx.recommendations.map((item) => {
      const place = placeIds.get(item.providerPlaceId);
      return {
        ...item,
        placeId: place ? String(place['id']) : item.placeId,
        placeSnapshot: place ? toPlaceSnapshot(place) : undefined,
      };
    });
    const artifact = {
      session_id: ctx.sessionId,
      task_id: ctx.taskId,
      schema_version: 2,
      artifact_type: 'recommendation_set',
      producer: 'result_coordinator',
      payload: { items: ctx.recommendations, warnings: ctx.degraded },
      confidence: ctx.recommendations.length > 0
        ? ctx.recommendations.reduce((sum, item) => sum + item.confidence, 0) / ctx.recommendations.length
        : null,
      warnings: ctx.degraded,
      requires_captain_approval: false,
      is_captain_visible: true,
    };
    const { data: storedArtifact, error: storedArtifactError } = await deps.serviceClient
      .from('agent_artifacts').insert(artifact).select('id').single();
    if (storedArtifactError) throw new OrchestrationError('artifact_write_failed', storedArtifactError.message);
    await appendEvent(deps, ctx.sessionId, ctx.commandId, ctx.taskId, 'artifact.created', {
      artifactId: (storedArtifact as Record<string, unknown>)['id'],
      artifactType: 'recommendation_set',
    });
    const { data: existingSet, error: existingError } = await serviceClient
      .from('recommendation_sets')
      .select('id')
      .eq('session_id', sessionId)
      .in('status', ['draft', 'generated', 'displayed', 'captain_selected'])
      .maybeSingle();
    if (existingError) throw new OrchestrationError('present_read_failed', existingError.message);
    if (!existingSet) {
      const { error } = await serviceClient.from('recommendation_sets').insert({
        session_id: sessionId,
        task_id: taskId,
        artifact_id: (storedArtifact as Record<string, unknown>)['id'],
        status: 'generated',
        items: ctx.recommendations,
      });
      if (error) throw new OrchestrationError('present_write_failed', error.message);
    }
    return { summary: `已汇总 ${ctx.recommendations.length} 条推荐结果`, complete: true };
  }, PHASE_TIMEOUT_MS.present, { taskId: ctx.taskId });
  if (presentOutcome.fatal || presentOutcome.status === 'timed_out') return;

  // ── 记忆提案：意图与忌口经队长确认后才写入长期记忆 ──────────────
  await proposeMemoryFromIntent(deps, ctx);

  // ── 会话收尾 ─────────────────────────────────────────────────────
  const rootStatus = ctx.degraded.length > 0 ? 'partial' : 'succeeded';
  await deps.serviceClient.from('agent_tasks').update({
    status: rootStatus,
    progress: rootStatus === 'succeeded' ? 100 : 60,
    finished_at: new Date().toISOString(),
    user_summary: rootStatus === 'succeeded' ? '队务官已完成全部工作' : '队务官已完成工作，但部分阶段降级',
  }).eq('id', ctx.taskId);
  const partial = ctx.degraded.length > 0;
  const hasDraft = ctx.tripDraftId !== null;
  await deps.serviceClient.from('squad_sessions').update({
    status: ctx.pendingDecision ? 'awaiting_captain_decision' : (partial ? 'partially_completed' : 'completed'),
  }).eq('id', sessionId);
  await deps.serviceClient.from('captain_commands').update({
    status: partial ? 'partially_completed' : 'completed',
  }).eq('id', commandId);
  await appendEvent(deps, sessionId, commandId, null, partial ? 'session.partially_completed' : 'session.completed', {
    summary: partial
      ? `部分完成：${ctx.degraded.join('；')}`
      : hasDraft
        ? `小队任务完成，${ctx.recommendations.length} 条推荐与路线草案待确认`
        : `小队任务完成，共 ${ctx.recommendations.length} 条推荐`,
    degraded: ctx.degraded,
    tripDraftId: ctx.tripDraftId,
  });
}

/**
 * 从意图生成记忆提案（propose_only 语义）。
 * 只有当指令中出现了可沉淀的偏好（忌口/预算/时段）时才提案，
 * 队长接受后才进入 user_memories。
 */
async function proposeMemoryFromIntent(deps: OrchestrationDeps, ctx: OrchestrationContext): Promise<void> {
  if (ctx.intent === null || ctx.memoryPolicy !== 'propose_only') return;
  const proposals: Array<{ operation: string; memoryKey: string; value: Record<string, unknown>; confidence: number }> = [];
  if (ctx.intent.avoid.length > 0) {
    proposals.push({
      operation: 'create',
      memoryKey: 'avoid',
      value: { items: ctx.intent.avoid, note: '来自队长指令' },
      confidence: 0.9,
    });
  }
  if (ctx.intent.budgetPerPersonMinor !== null) {
    proposals.push({
      operation: 'create',
      memoryKey: 'budget_per_person',
      value: { maxMinor: ctx.intent.budgetPerPersonMinor, note: '来自队长指令' },
      confidence: 0.8,
    });
  }
  if (proposals.length === 0) return;

  for (const proposal of proposals) {
    const { data: proposalRow, error } = await deps.serviceClient.from('memory_proposals').upsert({
      session_id: ctx.sessionId,
      task_id: ctx.taskId,
      user_id: ctx.userId,
      operation: proposal.operation,
      memory_key: proposal.memoryKey,
      proposed_value: proposal.value,
      confidence: proposal.confidence,
      status: 'proposed',
    }, { onConflict: 'session_id,memory_key', ignoreDuplicates: true }).select('id').maybeSingle();
    if (error) {
      console.error('memory proposal insert failed:', error.message);
      continue;
    }
    if (!proposalRow) continue;
    await appendEvent(deps, ctx.sessionId, ctx.commandId, null, 'memory.proposed', {
      memoryKey: proposal.memoryKey,
      value: proposal.value,
      confidence: proposal.confidence,
    });
  }
}

async function persistPlaces(
  deps: OrchestrationDeps,
  places: PlaceCandidate[],
): Promise<Map<string, Record<string, unknown>>> {
  const placeRows = new Map<string, Record<string, unknown>>();
  for (const place of places) {
    const fetchedAt = new Date().toISOString();
    const { data, error } = await deps.serviceClient
      .from('places')
      .upsert({
        provider: 'amap',
        provider_place_id: place.provider_place_id,
        name: place.name,
        category: place.category,
        address: place.address,
        latitude: place.latitude,
        longitude: place.longitude,
        coordinate_system: 'gcj02',
        fetched_at: fetchedAt,
      }, { onConflict: 'provider,provider_place_id' })
      .select('id, provider_place_id, name, category, address, latitude, longitude, coordinate_system, fetched_at')
      .single();
    if (error || !data) throw new OrchestrationError('place_cache_write_failed', error?.message ?? '地点缓存写入失败');
    placeRows.set(place.provider_place_id, {
      ...(data as Record<string, unknown>),
      provider: 'amap',
      fetched_at: String((data as Record<string, unknown>)['fetched_at'] ?? fetchedAt),
      rating: place.rating,
      cuisine_tags: place.cuisine_tags,
      price_level: place.price_level,
      business_status: place.business_status,
    });
  }
  return placeRows;
}

function toPlaceSnapshot(place: Record<string, unknown>): PlaceSnapshot {
  return {
    id: String(place['id']),
    provider_place_id: String(place['provider_place_id']),
    name: String(place['name']),
    category: (place['category'] as string | null) ?? null,
    address: (place['address'] as string | null) ?? null,
    latitude: (place['latitude'] as number | null) ?? null,
    longitude: (place['longitude'] as number | null) ?? null,
    rating: (place['rating'] as number | null) ?? null,
    cuisine_tags: (place['cuisine_tags'] as string[] | null) ?? null,
    price_level: (place['price_level'] as number | null) ?? null,
    business_status: (place['business_status'] as 'open' | 'closed' | 'unknown' | null) ?? null,
    provenance: 'amap',
    coordinate_system: (place['coordinate_system'] as 'gcj02' | 'wgs84') ?? 'gcj02',
    fetched_at: String(place['fetched_at']),
  };
}

/** 路线默认锚定“今天/明天 18:00”晚餐（MVP：无会话内具体日期时使用）。 */
function nextDinnerDate(): string {
  return new Date().toISOString().slice(0, 10);
}

/** 执行单阶段：建任务行 → running → 事件 → 成功/失败收敛，含一次性重试。 */
async function runPhase(
  deps: OrchestrationDeps,
  ctx: OrchestrationContext,
  role: AgentRole,
  phaseName: string,
  work: PhaseWork,
  timeoutMs: number,
  options: { taskId?: string } = {},
): Promise<PhaseOutcome> {
  const taskId = options.taskId ?? await createTask(deps, ctx.sessionId, ctx.commandId, role);
  const fatal = phaseName === 'intent' || phaseName === 'map' || phaseName === 'recommend' || phaseName === 'present';
  let lastErrorCode = `${phaseName}_failed`;
  let lastTimedOut = false;

  await deps.serviceClient.from('agent_tasks').update({
    status: 'running',
    started_at: new Date().toISOString(),
    progress: 10,
  }).eq('id', taskId);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, 'task.started', { role, phase: phaseName });
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, 'task.progressed', { role, phase: phaseName, progress: 10 });

  for (let attemptNumber = 0; attemptNumber < 2; attemptNumber++) {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let timedOut = false;
    let attemptActive = true;
    const workPromise = work(controller.signal, taskId);
    const attemptPromise = workPromise.then(async (result) => {
      if (!attemptActive || timedOut || controller.signal.aborted) throw new PhaseTimeoutError();
      await persistPhaseResult(
        deps,
        ctx,
        taskId,
        role,
        result.summary,
        result.complete,
        result.artifact,
      );
      return result;
    });
    const timeoutPromise = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        timedOut = true;
        attemptActive = false;
        controller.abort();
        reject(new PhaseTimeoutError());
      }, timeoutMs);
    });

    try {
      const { summary, complete, artifact } = await Promise.race([attemptPromise, timeoutPromise]);
      if (timedOut || controller.signal.aborted) throw new PhaseTimeoutError();
      return { status: complete ? 'succeeded' : 'partial', fatal: false, taskId };
    } catch (error) {
      lastTimedOut = error instanceof PhaseTimeoutError;
      lastErrorCode = lastTimedOut ? `${phaseName}_timeout` : `${phaseName}_failed`;
      console.error(`[${phaseName}] attempt failed:`, lastErrorCode);
      void attemptPromise.catch((lateError) => {
        console.error(`[${phaseName}] late attempt failed:`, lateError instanceof Error ? lateError.message : String(lateError));
      });
    } finally {
      attemptActive = false;
      if (timer !== undefined) clearTimeout(timer);
    }

    if (attemptNumber === 0) {
      await deps.serviceClient.from('agent_tasks').update({ status: 'retrying', retry_count: 1 }).eq('id', taskId);
    }
  }

  const status = lastTimedOut ? 'timed_out' : (fatal ? 'failed' : 'partial');
  if (fatal || lastTimedOut) {
    await deps.serviceClient.from('agent_tasks').update({
      status,
      error_code: lastErrorCode,
      user_summary: lastTimedOut ? `${phaseName} 阶段超时` : `${phaseName} 阶段失败`,
      finished_at: new Date().toISOString(),
    }).eq('id', taskId);
    if (lastTimedOut) {
      await deps.serviceClient.from('agent_tasks').update({
        status: 'timed_out',
        error_code: lastErrorCode,
        user_summary: 'Agent 执行超时，请稍后重试。',
        finished_at: new Date().toISOString(),
      }).eq('id', ctx.taskId);
      await deps.serviceClient.from('squad_sessions').update({ status: 'timed_out' }).eq('id', ctx.sessionId);
      await deps.serviceClient.from('captain_commands').update({ status: 'failed' }).eq('id', ctx.commandId);
      await appendEvent(deps, ctx.sessionId, ctx.commandId, ctx.taskId, 'session.failed', {
        summary: 'Agent 执行超时，请稍后重试。',
        code: lastErrorCode,
      });
    } else {
      await failSession(deps, ctx.sessionId, ctx.commandId, ctx.taskId, lastErrorCode, `${phaseName} 阶段执行失败`);
    }
    return { status, fatal: true, taskId, errorCode: lastErrorCode };
  }
  await deps.serviceClient.from('agent_tasks').update({
    status,
    user_summary: lastTimedOut ? `${phaseName} 阶段超时` : (fatal ? `${phaseName} 阶段失败` : `${phaseName} 阶段降级跳过`),
    error_code: lastErrorCode,
    finished_at: new Date().toISOString(),
  }).eq('id', taskId);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, fatal || lastTimedOut ? 'task.failed' : 'task.partial', {
    role,
    summary: lastTimedOut ? `${phaseName} 阶段超时` : (fatal ? `${phaseName} 阶段失败` : `${phaseName} 阶段降级跳过`),
  });
  if (!fatal && !lastTimedOut) ctx.degraded.push(`${phaseName} 降级`);
  return { status, fatal: fatal || lastTimedOut, taskId, errorCode: lastErrorCode };
}

async function persistPhaseResult(
  deps: OrchestrationDeps,
  ctx: OrchestrationContext,
  taskId: string,
  role: AgentRole,
  summary: string,
  complete: boolean,
  artifact: PhaseResult['artifact'],
): Promise<void> {
  if (artifact) {
    const { data: artifactRow, error: artifactError } = await deps.serviceClient
      .from('agent_artifacts')
      .insert({
        session_id: ctx.sessionId,
        task_id: taskId,
        schema_version: 1,
        artifact_type: artifact.type,
        producer: role,
        payload: artifact.payload,
        confidence: artifact.confidence ?? null,
        warnings: [],
        requires_captain_approval: false,
        is_captain_visible: true,
      })
      .select('id')
      .single();
    if (artifactError) throw new OrchestrationError('artifact_write_failed', artifactError.message);
    await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, 'artifact.created', {
      artifactId: (artifactRow as Record<string, unknown>)['id'],
      artifactType: artifact.type,
    });
  }
  const { error: taskError } = await deps.serviceClient.from('agent_tasks').update({
    status: complete ? 'succeeded' : 'partial',
    user_summary: summary,
    finished_at: new Date().toISOString(),
    progress: complete ? 100 : 60,
  }).eq('id', taskId);
  if (taskError) throw new OrchestrationError('task_finalize_failed', taskError.message);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, complete ? 'task.succeeded' : 'task.partial', { summary, role });
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
    plan_id: deps.planId,
    role,
    status: 'queued',
  }).select('id').single();
  if (error || !data) {
    throw new OrchestrationError('task_create_failed', error?.message ?? 'task insert returned no id');
  }
  const id = String(data['id']);
  const { error: stepError } = await deps.serviceClient.from('agent_steps').insert({
    task_id: id,
    plan_id: deps.planId,
    kind: role,
    status: 'queued',
  });
  if (stepError) throw new OrchestrationError('step_create_failed', stepError.message);
  await appendEvent(deps, sessionId, commandId, id, 'task.created', { role });
  return id;
}


async function updatePhaseProgress(
  deps: OrchestrationDeps,
  ctx: OrchestrationContext,
  taskId: string,
  progressValue: number,
  summary: string,
): Promise<void> {
  const { error } = await deps.serviceClient.from('agent_tasks').update({
    progress: progressValue,
    user_summary: summary,
  }).eq('id', taskId);
  if (error) throw new OrchestrationError('task_progress_update_failed', error.message);
  await appendEvent(deps, ctx.sessionId, ctx.commandId, taskId, 'task.progressed', {
    role: 'map_explorer',
    phase: 'map',
    progress: progressValue,
    summary,
  });
}

async function finalizeTopLevelFailure(
  deps: OrchestrationDeps,
  sessionId: string,
  commandId: string,
  taskId: string,
): Promise<void> {
  const safeSummary = 'Agent 执行失败，请稍后重试。';
  try {
    await deps.serviceClient.from('agent_tasks').update({
      status: 'failed',
      error_code: 'orchestration_failed',
      user_summary: safeSummary,
      finished_at: new Date().toISOString(),
    }).eq('id', taskId);
  } catch (error) {
    console.error('failed to finalize root task:', error instanceof Error ? error.message : String(error));
  }
  try {
    await deps.serviceClient.from('squad_sessions').update({ status: 'failed' }).eq('id', sessionId);
  } catch (error) {
    console.error('failed to finalize session:', error instanceof Error ? error.message : String(error));
  }
  try {
    await deps.serviceClient.from('captain_commands').update({ status: 'failed' }).eq('id', commandId);
  } catch (error) {
    console.error('failed to finalize command:', error instanceof Error ? error.message : String(error));
  }
  try {
    await appendEvent(deps, sessionId, commandId, taskId, 'session.failed', { summary: safeSummary, code: 'orchestration_failed' });
  } catch (error) {
    console.error('failed to append orchestration failure event:', error instanceof Error ? error.message : String(error));
  }
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
    throw new OrchestrationError('event_write_failed', error.message);
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
  commandId: string,
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
  await deps.serviceClient.from('captain_commands').update({ status: 'failed' }).eq('id', commandId);
  await appendEvent(deps, sessionId, commandId, taskId, 'session.failed', { summary: message, code });
}

async function finishWithoutResults(deps: OrchestrationDeps, ctx: OrchestrationContext): Promise<void> {
  await deps.serviceClient.from('agent_tasks').update({
    status: 'succeeded',
    progress: 100,
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
