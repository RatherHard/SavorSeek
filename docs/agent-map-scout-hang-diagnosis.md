# 地图侦察员卡死诊断与修复交接

## 1. 问题概述

用户反馈：Agent 执行到“地图侦察员”阶段后卡住，进度不再变化，任务长时间没有完成或失败提示。

本诊断基于当前 `dev` 分支代码（截至 2026-08-30），重点追踪了 Flutter 客户端、Supabase Edge Function、Agent 编排器以及高德地点检索服务之间的调用链。

**当前状态：** 已完成诊断，尚未留下有效生产代码修复。现有 Flutter Agent 测试和静态分析均通过，但后端 Edge Function 尚未完成可验证的修复提交。

## 2. 完整调用链

```text
Flutter ExplorePage
  └─ AgentController.submit()
      └─ SupabaseAgentRepository.submit()
          └─ Edge Function: agent
              └─ RPC: submit_captain_command
                  ├─ 创建 squad_sessions
                  ├─ 创建 captain_commands
                  ├─ 创建 agent_plans
                  ├─ 创建 result_coordinator 根任务
                  └─ 写入 session.created / command.accepted
              └─ EdgeRuntime.waitUntil(runOrchestration())
                  ├─ Phase A: intent_interpreter + preference_advisor
                  ├─ Phase B: map_explorer（当前故障点）
                  │   └─ searchAmapPlaces()
                  │       └─ fetch(高德 Web Service API)
                  ├─ Phase C: fact_checker
                  ├─ Phase D: recommendation_decider
                  ├─ Phase E: route_planner（可选）
                  └─ Phase F: result_coordinator
```

关键文件：

- `apps/mobile/lib/features/explore/explore_page.dart`
- `apps/mobile/lib/features/agent/agent_controller.dart`
- `apps/mobile/lib/features/agent/agent_repository.dart`
- `apps/mobile/lib/features/agent/agent_workspace_panel.dart`
- `supabase/functions/agent/index.ts`
- `supabase/functions/agent/orchestrator.ts`
- `supabase/functions/places-search/amap.ts`
- `supabase/functions/trip-route/amap.ts`

## 3. 已确认的主要根因

### 3.1 阶段级 AbortController 没有传入实际工作

文件：`supabase/functions/agent/orchestrator.ts`

当前 `runPhase` 在约 469-474 行创建了阶段级控制器和定时器：

```ts
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), timeoutMs);
const { summary, complete, artifact } = await work();
```

但是：

- `work` 的函数签名不接收 `AbortSignal`；
- 地图阶段调用 `searchAmapPlaces(query, requireAmapKey())` 时没有传 signal；
- 路线阶段调用 `resolveRoute(...)` 时同样没有传 signal；
- 定时器到期后只会把一个未被使用的 controller 标记为 aborted；
- `await work()` 仍可能无限等待，因此重试和最终失败收敛永远不会执行。

高德 POI 客户端自身有 8 秒 `AbortSignal.timeout`，但它只能保护单次高德 fetch，不能保护：

- 其他外部调用；
- Supabase 数据库读写；
- 事件写入 RPC；
- 地点缓存写入；
- 未来增加的阶段工作。

**修复要求：**

```ts
type PhaseWork = (
  signal: AbortSignal,
  phaseTaskId: string,
) => Promise<PhaseResult>;
```

阶段工作必须使用传入 signal；`runPhase` 还应使用 `Promise.race` 或等价机制确保即使下游不响应 abort，编排器自身也会在 deadline 后返回并进入终态收敛。

### 3.2 地图任务进度只写事件，没有写入任务投影

文件：`supabase/functions/agent/orchestrator.ts`

当前阶段启动时写入：

```ts
await appendEvent(..., 'task.progressed', {
  role,
  phase: phaseName,
  progress: 10,
});
```

但是数据库任务 `agent_tasks.progress`：

- 默认值为 0；
- 直到阶段成功时才被写成 100；
- 阶段 partial 时才被写成 60；
- 阶段工作过程中没有更新。

地图阶段当前没有中间进度事件。即使增加了事件，Flutter 侧也不会直接使用事件 payload 作为进度来源：

- `AgentEventReducer` 只做事件去重、序列检查和 snapshot 恢复标记；
- `AgentTask.fromJson` 读取数据库投影中的 `progress`；
- `agent_workspace_panel.dart` 显示 `task.progress`。

因此地图任务运行期间通常表现为 0%，完成时才突然跳到 100%。

**修复要求：**

- 阶段开始实际更新 `agent_tasks.progress = 10`；
- 地图检索开始更新实际的 `map_explorer` 任务到 25%；
- 高德返回并完成归一化后更新到 80%；
- 成功更新到 100%；
- partial 更新到 60%；
- 失败/超时写入明确终态和最后进度；
- 进度事件 payload 与数据库字段保持一致。

注意：不能继续用 `ctx.taskId` 更新地图进度。`ctx.taskId` 是提交时创建的根 `result_coordinator` 任务 ID，地图进度必须写入 `runPhase` 创建的阶段任务 ID。

### 3.3 fatal 阶段失败可能被后续逻辑覆盖成成功

当前 `runPhase` 返回 `Promise<void>`。当地图阶段两次失败时，它会：

1. 将 `map_explorer` 任务标记为 `failed`；
2. 调用 `failSession`，将 session 标记为 `failed`；
3. 但调用方不知道本阶段失败；
4. 主流程继续执行；
5. 因 `ctx.candidates` 为空，进入 `finishWithoutResults()`；
6. `finishWithoutResults()` 将根任务和 session 改写为 `succeeded/completed`。

结果可能是：

```text
map_explorer = failed
squad_sessions = completed
root task = succeeded
```

Recommend、Present 等 fatal 阶段也存在相同风险。

**修复要求：**

让 `runPhase` 返回显式阶段结果，例如：

```ts
interface PhaseOutcome {
  status: 'succeeded' | 'partial' | 'failed' | 'timed_out';
  fatal: boolean;
}
```

调用方必须在以下情况立即停止主流程：

- `fatal === true`；
- `status === 'timed_out'`。

特别是地图阶段失败/超时后，绝对不能继续进入 `finishWithoutResults()`。

### 3.4 编排器缺少顶层异常收敛

文件：`supabase/functions/agent/orchestrator.ts`

`runOrchestration` 当前没有总的 `try/catch`。以下异常可能直接使 `EdgeRuntime.waitUntil` 中的 Promise rejected：

- command 查询失败；
- plan 查询失败；
- `createTask` 失败；
- `agent_steps` 插入失败；
- `append_squad_event` RPC 失败；
- artifact 写入失败；
- 地点缓存写入失败；
- recommendation set 写入失败；
- session/command 最终状态更新失败；
- 未预期的运行时异常。

由于 HTTP 响应已经返回，客户端只会看到已接受的任务，而数据库可能永久停留在：

```text
session = dispatching / working
root task = running
map task = queued / running
```

**修复要求：**

在公开的 `runOrchestration` 外层增加顶层捕获，内部主体可改名为 `runOrchestrationInternal`：

```ts
export async function runOrchestration(...): Promise<void> {
  try {
    await runOrchestrationInternal(...);
  } catch (error) {
    await finalizeTopLevelFailure(...);
  }
}
```

`finalizeTopLevelFailure` 必须 best-effort：

- 尝试将根 task 标为 `failed`；
- 尝试将 session 标为 `failed`；
- 尝试将 command 标为 `failed`；
- 追加 `session.failed` 事件；
- finalizer 自身失败时只记录服务端日志，不能再次抛出。

用户可见响应中不要返回原始 PostgreSQL 错误、内部表名或约束名。

## 4. 相关但次要的问题

### 4.1 初始根任务与 Phase F 重复创建

提交 RPC 已创建一个 `result_coordinator` 根任务，编排开始时把它设置为 `running`；但 Phase F 又调用：

```ts
runPhase(..., 'result_coordinator', 'present', ...)
```

这会创建第二个 `result_coordinator` 任务。

正常完成路径只收敛第二个阶段任务，初始根任务可能永久保持：

```text
result_coordinator / running / 0%
```

这会制造“整体任务仍在运行”的假象。

本次最低限度应在正常收尾时将根任务更新为：

- 成功：`succeeded`, `progress = 100`；
- 部分完成：`partial`, `progress = 60`；
- 失败：`failed`；
- 超时：`timed_out`（仅 `agent_tasks` 支持该状态）。

### 4.2 地图失败后的重试任务语义错位

文件：`supabase/functions/agent/index.ts` 与 `supabase/migrations/20260829000022_agent_retry_and_queries.sql`

当前 `retry_agent_task` 接收的是失败阶段任务 ID，但 `index.ts` 把 RPC 返回的 task ID 直接作为 `runOrchestration` 的根任务 ID。

如果用户点击“地图侦察员”重试：

- 原 `map_explorer` 任务被置回 queued；
- 完整编排从 Phase A 重新运行；
- 原地图任务却被当作 root `result_coordinator` 使用；
- 新的 map 阶段又创建另一条 `map_explorer` 任务；
- 可能出现重复阶段、重复 artifact、重复推荐和任务状态混乱。

本次可以先不重做完整阶段级重试，但必须避免将阶段 task ID 伪装成 root task ID。可选方案：

1. 只允许重试 root task，并明确语义为“重跑整条编排”；或
2. retry RPC 返回对应的 root task ID，另行记录要重试的阶段；或
3. 实现真正的阶段级 retry，从失败阶段重新开始。

### 4.3 Realtime 订阅存在首事件竞态

文件：`apps/mobile/lib/features/agent/agent_controller.dart`

当前 `_activate` 流程是：

1. `loadSession` 获取快照；
2. 安装快照；
3. 建立 Realtime 订阅。

在第 1 步和第 3 步之间写入的事件可能既不在初始快照，也不会触发新订阅。

最低限度应在订阅成功后执行一次 `refresh()`，通过 `listEvents`/最终 snapshot 补齐订阅前产生的事件。

此外，当前订阅未处理：

- `SUBSCRIBED`；
- `CHANNEL_ERROR`；
- `TIMED_OUT`；
- `CLOSED`。

Realtime 丢失时应有可见同步错误或有界重试，而不是静默等待。

### 4.4 提交阶段可能无可见 loading

文件：`apps/mobile/lib/features/agent/agent_controller.dart`、`agent_workspace_panel.dart`、`explore_page.dart`

提交时：

- `isSubmitting = true`；
- 指令栏被禁用；
- 尚未有 session 时，工作区返回 `SizedBox.shrink()`；
- 如果 `functions.invoke` 或初始 `loadSession` 挂起，用户既不能继续提交，也看不到明确 loading/超时错误。

这不是地图后端阶段卡死的主根因，但会放大用户感知。

可作为后续修复：

- 为 repository invoke 设置客户端超时；
- 在 submit 状态下显示明确 loading；
- 超时后允许重试，且沿用原 `clientRequestId` 保证幂等。

### 4.5 取消竞态

取消发生在高德请求或数据库写入期间时，当前编排器可能在取消后继续：

- 写入 artifact；
- 将 task 标为 succeeded；
- 将 session 标为 completed；
- 追加 session.completed。

`checkCancelled` 只在阶段之间执行，不能保护“检查后到写入前”的竞态。

后续应使用数据库条件更新、task version 或 execution token 保证 cancelled 是不可覆盖的终态。本次至少应在阶段结束前再次检查取消状态，并避免旧 worker 覆盖终态。

## 5. 关键状态与数据契约

### 5.1 Agent task 状态

定义于 `supabase/migrations/20260828000015_agent_squad_schema.sql`：

```text
queued
assigned
running
waiting_for_dependency
waiting_for_captain
succeeded
partial
retrying
timed_out
failed
cancelled
```

### 5.2 Session 状态

```text
idle
receiving_command
interpreting
dispatching
working
awaiting_captain_decision
applying_decision
completed
partially_completed
timed_out
failed
cancelled
```

### 5.3 Command 状态

当前不支持 `timed_out`：

```text
accepted
processing
completed
partially_completed
failed
cancelled
```

因此：

- `agent_tasks` 可以使用 `timed_out`；
- `captain_commands` 超时应保持 `failed`，并通过 `error_code` 或事件 payload 区分超时；
- 不要在没有 migration 的情况下向 `captain_commands.status` 写入 `timed_out`。

### 5.4 Realtime 与事件

`squad_events` 已加入 `supabase_realtime` publication，且已有 authenticated select policy。客户端目前只监听 `squad_events INSERT`，收到事件后重新读取完整 projection。

这条策略本身可以工作，前提是：

- 事件确实被写入；
- 任务投影同步更新；
- 订阅建立前后的事件通过 catch-up refresh 补齐；
- 订阅失败有显式处理。

`AgentEventReducer` 当前只负责：

- 事件 ID 去重；
- sequence gap 检测；
- 触发 snapshot recovery 标志。

它不会把 `task.progressed` payload 投影为 `AgentTask.progress`。因此不能只修改 reducer，必须修复后端任务投影写入。

## 6. 推荐的最小修复范围

首批修改建议只涉及：

1. `supabase/functions/agent/orchestrator.ts`
   - 阶段工作接受 signal；
   - 地图进度写入真实 map task；
   - 阶段超时使用 `Promise.race`；
   - 返回显式阶段结果；
   - fatal/timeout 立即停止主流程；
   - 收敛 root task；
   - 顶层异常兜底。
2. `supabase/functions/places-search/amap.ts`
   - `searchAmapPlaces(query, key, signal?)`；
   - `fetchAmap(url, signal?)`；
   - 外部 signal 与现有 8 秒 provider timeout 组合，旧调用保持兼容。
3. `supabase/functions/trip-route/amap.ts`
   - `resolveRoute(..., signal?)`；
   - `fetchSegment(..., signal?)`；
   - `fetchAmap(..., signal?)`；
   - 保持旧调用兼容。
4. 可选客户端小改动：`apps/mobile/lib/features/agent/agent_controller.dart`
   - Realtime 订阅成功后立即 catch-up refresh；
   - 订阅错误时设置可见错误。

**本次不建议：**

- 新增数据库 migration；
- 重构成新的 Agent 类层次；
- 引入新的测试框架；
- 同时重做完整阶段级 retry；
- 修改 `docs/savedprompt/`。

## 7. 修复顺序

建议下一个 Agent 按以下顺序执行：

1. 先写回归测试或至少先建立可复现的 timeout/状态失败场景；
2. 修改 `places-search/amap.ts` 的 signal 参数；
3. 修改 `trip-route/amap.ts` 的 signal 参数；
4. 修改 `orchestrator.ts` 的 `PhaseWork` 签名和所有阶段 callback；
5. 在 map 阶段传递 signal，并将进度 25/80 写入 `map_explorer` task；
6. 将 `runPhase` 的 `await work()` 改为真正有 deadline 的执行；
7. 在两次失败后写入 `timed_out` 或 `failed`，并返回显式 outcome；
8. 在 map/recommend/present 等 fatal 阶段调用点立即停止；
9. 正常成功、partial、无结果、失败路径收敛 root task；
10. 增加顶层 best-effort failure finalizer；
11. 运行测试、静态分析和代码审查；
12. 在真实 Supabase 环境中验证任务、事件和 session 状态。

## 8. 回归测试要求

### 8.1 后端阶段超时

至少覆盖：

- `work` 正常完成；
- `work` 在 timeout 前完成；
- `work` 永不 resolve；
- timeout 时传入的 signal 已 aborted；
- `runPhase` 在 timeout 后释放控制权；
- 第一次失败后只重试一次；
- 两次失败后不再保持 `running` 或 `retrying`；
- 超时最终写入 `agent_tasks.status = timed_out`；
- 迟到的旧 Promise 不能把任务写回 succeeded。

### 8.2 地图阶段

- 高德成功响应生成候选地点；
- 地图 task 进度由 10 → 25 → 80 → 100；
- 高德 HTTP 200 但业务 `status = 0` 时仍抛出正确的 provider 错误；
- Key 缺失/无效不被误判为空结果；
- 地图两次失败后 session 不得被 `finishWithoutResults` 改成 completed；
- 地图阶段超时后不进入 Fact/Recommend/Present。

### 8.3 顶层异常

模拟以下任一操作失败：

- command 查询；
- task/step 创建；
- event RPC；
- artifact 写入；
- recommendation set 写入；
- session/command 状态更新。

断言：

- root task 尝试进入 failed；
- session 尝试进入 failed；
- command 尝试进入 failed；
- 不留下 rejected `waitUntil` 作为唯一结果；
- finalizer 自身异常不会继续向外抛。

### 8.4 Flutter

现有测试目录：

- `apps/mobile/test/agent/agent_controller_test.dart`
- `apps/mobile/test/agent/agent_event_reducer_test.dart`
- `apps/mobile/test/agent/agent_models_test.dart`
- `apps/mobile/test/agent/agent_workspace_panel_test.dart`

建议补充：

- `timed_out` task 模型解析；
- 地图 task 的 25/80/100 进度投影；
- 失败/超时任务显示重试按钮；
- Realtime 建立后 catch-up refresh；
- sequence gap 触发 snapshot recovery；
- 提交挂起时可见 loading/超时错误。

## 9. 验证命令

### Flutter Agent 测试

```powershell
Set-Location F:\SavorSeek\apps\mobile
flutter test test/agent
dart analyze
```

已验证结果：

```text
14 tests passed
No issues found!
```

### Edge Function

当前开发环境未发现 `deno` 可执行文件，因此不能在本机运行 `deno check` 或 Deno 单元测试。下一个 Agent 应：

- 先检查 CI/部署环境是否提供 Deno；
- 如可用，运行 `deno check` 和 Deno tests；
- 如不可用，至少通过 Supabase 本地函数环境或 CI 完成 TypeScript 校验。

### Supabase 本地验证

```powershell
supabase db reset
supabase db lint
supabase functions serve agent --env-file supabase/.env
```

验证数据库状态：

```sql
select id, status, active_command_id, projection_version, updated_at
from public.squad_sessions
where id = '<session-id>';

select id, role, status, progress, retry_count, error_code, started_at, finished_at, updated_at
from public.agent_tasks
where session_id = '<session-id>'
order by created_at;

select sequence, event_type, actor, task_id, payload, occurred_at
from public.squad_events
where session_id = '<session-id>'
order by sequence;
```

验证 Realtime publication：

```sql
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and tablename in ('squad_events', 'agent_tasks');
```

## 10. 完成标准

修复完成后，必须满足：

- 地图侦察员不会因未响应的工作 Promise 永久卡在 running；
- 地图请求可接收阶段级取消信号；
- 阶段 timeout 后最多执行一次重试并进入明确终态；
- 地图任务进度在数据库投影中实际变化；
- 地图失败不会被误判成“无结果但已完成”；
- 正常流程会收敛 root task；
- 顶层异常不会遗留长期 dispatching/running 状态；
- Flutter 既能通过 Realtime 接收更新，也能通过 refresh/list_events 恢复；
- 现有 Flutter Agent 测试保持通过；
- Edge Function 通过 Deno/CI 类型检查；
- 未新增无关数据库迁移或修改 `docs/savedprompt/`。

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-08-30 | 初始诊断与修复交接记录 |
