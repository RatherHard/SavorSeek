/**
 * Agent 编排的共享类型与错误定义。
 *
 * 契约来源：docs/architechture/Agent小队与Flutter前端交互对接设计.md 与
 * docs/multi-agent-arch.md。事件与任务状态值与数据库迁移
 * 20260829000020_agent_squad_commands.sql 的 CHECK 约束保持一致。
 */

/** Agent 角色，与 agent_tasks.role 的约束一致。 */
export type AgentRole =
  | 'result_coordinator'
  | 'intent_interpreter'
  | 'map_explorer'
  | 'preference_advisor'
  | 'content_researcher'
  | 'fact_checker'
  | 'recommendation_decider'
  | 'route_planner';

/** 任务状态，与 agent_tasks.status 的约束一致。 */
export type AgentTaskStatus =
  | 'queued'
  | 'assigned'
  | 'running'
  | 'waiting_for_dependency'
  | 'waiting_for_captain'
  | 'succeeded'
  | 'partial'
  | 'retrying'
  | 'timed_out'
  | 'failed'
  | 'cancelled';

/** 事件类型，与前端 Reducer（9.3 节）约定一致。 */
export type SquadEventType =
  | 'session.created'
  | 'command.accepted'
  | 'intent.normalized'
  | 'task.created'
  | 'task.started'
  | 'task.progressed'
  | 'task.succeeded'
  | 'task.partial'
  | 'task.failed'
  | 'artifact.created'
  | 'recommendation.proposed'
  | 'trip.draft.created'
  | 'decision.required'
  | 'session.completed'
  | 'session.partially_completed'
  | 'session.failed'
  | 'session.cancelled';

/** 需求理解输出的结构化约束。缺省项显式为 null（成功标准：缺省不丢失）。 */
export interface ParsedIntent {
  keywords: string | null;
  city: string | null;
  area: string | null;
  mealPeriod: 'breakfast' | 'lunch' | 'afternoon_tea' | 'dinner' | 'late_night' | null;
  partySize: number | null;
  budgetPerPersonMinor: number | null;
  avoid: string[];
  needRoute: boolean;
}

/** 地图候选（归一化后进入 places 缓存的形状，与 NormalizedPlace 对齐）。 */
export interface PlaceCandidate {
  provider_place_id: string;
  name: string;
  category: string | null;
  address: string | null;
  latitude: number | null;
  longitude: number | null;
  rating: number | null;
  cuisine_tags: string[] | null;
  price_level: number | null;
  business_status: 'open' | 'closed' | 'unknown' | null;
}

/** 事实核验后的候选。 */
export interface VerifiedPlace extends PlaceCandidate {
  verified: boolean;
  confidence: number;
  warnings: string[];
}

/** 推荐项。分数只来自规则与数据字段，LLM 不凭空生成事实。 */
export interface RecommendationItem {
  placeId: string | null;
  name: string;
  rank: number;
  score: number;
  matchSummary: string;
  reasonCodes: string[];
  confidence: number;
  riskFlags: string[];
}

/** 编排阶段上下文，阶段函数之间只通过它传递结构化产物。 */
export interface OrchestrationContext {
  sessionId: string;
  commandId: string;
  planId: string;
  taskId: string;
  userId: string;
  rawText: string;
  taskType: string;
  context: Record<string, unknown>;
  memoryPolicy: 'disabled' | 'read_only' | 'propose_only';
  constraints: Record<string, unknown>;
  intent: ParsedIntent | null;
  memoryNotes: string[];
  candidates: PlaceCandidate[];
  verified: VerifiedPlace[];
  recommendations: RecommendationItem[];
  routePath: Array<{ latitude: number; longitude: number }> | null;
  tripDraftId: string | null;
  pendingDecision: boolean;
  degraded: string[];
}

/** 编排错误。code 用于服务端日志与降级判断，不进入用户可见事件。 */
export class OrchestrationError extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = 'OrchestrationError';
  }
}
