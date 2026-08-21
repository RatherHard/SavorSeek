# Agent 小队与 Flutter 前端交互对接设计

## 1. 文档说明

### 1.1 文档目的

本文定义 SavorSeek 中“队长指挥拟人化 Agent 小队”与 Flutter 前端之间的交互模型、任务编排边界、结构化数据契约和实时同步方式，作为后续以下工作的共同设计依据：

- `apps/mobile` 中 Agent 工作区、指令栏、地图投影和行程投影的实现；
- `packages/domain` 中 Agent 任务、地点候选、行程草案和队长决策点的领域模型；
- `packages/contracts` 中请求、响应、Artifact 和 Realtime 事件契约；
- `supabase/functions/agent` 中任务创建、Agent 编排、工具调用和结果汇总；
- Supabase PostgreSQL、Realtime、RLS 和审计模型的设计。

本文只定义对接设计，不代表相关代码、数据库表、Agent 编排或共享契约已经全部实现。文中出现的字段和状态属于目标契约，正式落地时应通过共享 Schema、数据库迁移和契约测试确认。

### 1.2 适用范围

本文覆盖：

- `P-MAP` 探索页中的地图主工作区；
- 底部 Agent 指令栏；
- Agent 小队角色卡、状态和阶段汇报；
- 推荐结果、地点候选和地图标记；
- `P-TRIP` 行程页中的时间轴、路线和冲突提示；
- Agent 任务的创建、执行、取消、恢复和失败；
- Supabase Realtime 事件与客户端断线恢复；
- 记忆提案、行程草案和其他需要队长确认的结果；
- 工具调用权限、数据来源、不确定性和安全边界。

### 1.3 不在本文范围内

以下内容不在本版本详细设计范围内：

- 复杂 3D 数字人、实时语音或视频形象；
- 餐厅订座、支付、订单履约和商户后台；
- 多用户共同编辑同一行程；
- 未经授权抓取内容平台；
- 完整导航能力和专业级实时交通承诺；
- Agent 内部思维链、系统提示词和模型原始推理过程；
- 具体 LLM 供应商 SDK、模型名称和外部服务 API 参数。

### 1.4 当前项目基线

当前仓库已经形成以下可核对的基础：

- Flutter 客户端采用 `P-MAP`、`P-TRIP`、`P-MINE` 三个顶层入口；
- 探索页以地图为主要内容，底部固定 Agent 指令栏；
- Agent 指令栏采用指令式输入，不采用传统聊天气泡列表；
- `IndexedStack` 用于保持顶层页面切换时的状态；
- 高德地图 SDK 已接入探索页，但地图瓦片实际渲染和鉴权仍有待复测；
- 行程表数据模型已经在 [`docs/architechture/行程表数据模型.md`](./行程表数据模型.md) 中定义；
- Agent Edge Function、共享契约包和完整 Agent 任务数据模型仍处于后续建设阶段。

### 1.5 设计状态与命名约定

本文描述的是目标对接设计，不是当前实现清单。除“当前项目基线”明确列出的内容外，正文中的“必须”“负责”和“支持”均表示后续实现应满足的架构约束。

| 状态 | 含义 |
|------|------|
| 已实现 | 当前代码或测试已经能够证明 |
| 已设计 | 本文或关联架构文档已经定义，但尚未完成代码落地 |
| 部分实现 | 已有基础能力，但尚未形成完整闭环 |
| 待确认 | 需要在实现前形成产品或架构决策 |
| 待验证 | 已有实现或方案，但缺少运行期、真机或集成证据 |

命名分层约定如下：

- PostgreSQL 表和字段使用 `snake_case`，例如 `agent_tasks`、`source_agent_task_id`；
- 对外 JSON 契约统一使用 `camelCase`，例如 `sourceAgentTaskId`、`expectedRevision`；
- Dart 和 TypeScript 模型使用各自语言的 `camelCase` 命名；
- 数据库字段与 API 字段的转换只发生在 Repository、DTO Mapper 或 Edge Function Adapter 中；
- `revision` 是服务端当前行程修订号，写命令中的 `expectedRevision` 是客户端声明的预期修订号，二者不能混用。

当前仓库实际使用的架构文档目录名为 `docs/architechture/`。该目录名与项目规范中的 `docs/architecture/` 拼写不同；在目录统一前，新增文档应沿用当前实际目录，避免产生两个并行目录。



### 2.1 交互模型：队长指挥工作台，而不是聊天窗口

SavorSeek 不采用“用户向一个聊天机器人提问，机器人连续回复文本”的交互模型。用户在产品中扮演**队长**，Agent 以具有明确职责、稳定身份和虚拟人物形象的队员组成一支小队。

用户的主要动作是：

1. 观察地图和当前行程；
2. 选择地点、区域、时间段或筛选条件；
3. 通过指令栏下达任务；
4. 查看队员分工、任务状态和阶段汇报；
5. 审阅推荐、证据、风险和不确定性；
6. 做出选择、确认、拒绝、锁定或修改；
7. 要求小队重新规划或继续探索。

自然语言可以作为指令的表达方式，但不是系统的核心数据模型。后端必须把用户指令转换为结构化任务和约束，前端必须把 Agent 过程投影为工作状态、结果卡和决策卡，而不是拼接成聊天记录。

### 2.2 地图和行程是两个主要工作区

- **地图是空间工作区**：展示地点候选、推荐优先级、选中状态、路线和风险。
- **行程是时间工作区**：展示日期、时段、地点顺序、锁定字段、冲突和预算。
- **Agent 小队是协作工作区**：展示谁正在工作、正在解决什么问题、产出了什么结果、哪里需要队长决策。
- **指令栏是任务入口**：接收队长指令，不承担业务编排。

三个工作区共享同一组领域对象和服务端版本，不允许地图、Agent 工作室和行程页各自维护互相独立的事实副本。

### 2.3 结构化产物优先于自由文本

Agent 之间不通过自由文本互相传递业务事实。每个阶段应生成带版本、来源、置信度和输入引用的结构化 Artifact。

自由文本只用于：

- 阶段性工作汇报；
- 面向队长的结果摘要；
- 错误和降级说明；
- 推荐理由的可读表达。

业务执行、硬性约束、行程写入和记忆写入必须依赖结构化字段和确定性校验。

### 2.4 Realtime 是通知通道，数据库是事实源

任务、步骤、Artifact、行程草案、决策点和最终结果必须先持久化，再通过 Realtime 通知客户端。

Realtime 不承担以下职责：

- 唯一保存任务状态；
- 传输完整业务结果；
- 代替数据库事务；
- 作为不可恢复的消息队列；
- 传输每个模型 token 或内部推理过程。

客户端断线后必须能够通过“最新快照 + 事件补齐”恢复工作区状态。

### 2.5 Agent 只能提出高影响变更，不能越权执行

以下操作默认生成 Proposal 或 Draft，必须经过队长确认后才能应用：

- 新增、修改或删除长期记忆；
- 修改已经确认的行程；
- 替换或删除用户锁定的行程节点；
- 放宽预算、时间、忌口或其他硬性约束；
- 用低可信度信息覆盖已经确认的事实；
- 产生外部副作用的操作。

“虚拟人物表现得很有把握”不能替代确认机制，也不能改变权限边界。

### 2.6 MVP 的队长控制范围

MVP 中“队长指挥”包含：

- 提交新指令；
- 取消当前小队任务；
- 重新提交修改后的指令；
- 选择、比较、收藏或拒绝推荐；
- 接受、拒绝或编辑记忆提案；
- 查看、修改、锁定和确认行程草案。

MVP 暂不支持队长直接编辑内部任务图、将任务重新分派给指定队员或修改 Agent 的工具权限。任务“恢复”通过断线后的会话快照恢复，或由队长重新提交指令实现，不等同于开放内部任务图编辑。

### 2.7 拟人化表现的 MVP 边界

MVP 的拟人化最低实现是：稳定的角色身份、职责名称、静态或轻量 2D 头像、任务状态、阶段汇报和决策请求。复杂 3D 形象、实时语音、连续表情动画和数字人动作属于后续增强能力，不作为本对接设计的必要交付物。

---

## 3. 目标架构与职责边界

```text
┌────────────────────────────────────────────────────────────┐
│                         Flutter Mobile                     │
│                                                            │
│  P-MAP                    Agent 工作区          P-TRIP      │
│  ├─ 地图主画布             ├─ 队员角色卡          ├─ 时间轴  │
│  ├─ 地点标记               ├─ 任务阶段            ├─ 路线    │
│  ├─ 推荐卡                 ├─ 汇报摘要            ├─ 冲突    │
│  ├─ 筛选与选区             └─ 决策卡              └─ 编辑    │
│  └─ Agent 指令栏                                            │
│              │                                               │
│       Application / Repository / Event Reducer               │
└──────────────┬──────────────────────────────────────────────┘
               │ Authenticated API + Realtime
┌──────────────▼──────────────────────────────────────────────┐
│                 Supabase Edge Functions                     │
│                                                            │
│  Command API       Query API       Decision API              │
│       │                 │                 │                  │
│       └──────────── Task Orchestrator ────┘                  │
│                              │                               │
│  需求理解 → 硬性约束校验 → 地图检索 / 记忆读取 / 内容研究      │
│          → 事实核验 → 推荐决策 → 路线规划 → 结果汇总          │
│                                                            │
│  Tool Gateway / Policy / Retry / Timeout / Budget / Audit     │
└──────────────┬──────────────────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────────────────┐
│                         Supabase                            │
│  PostgreSQL: 任务、步骤、Artifact、事件、行程、记忆、来源     │
│  RLS: 用户私有数据隔离       Realtime: 状态通知与增量同步      │
│  Storage: 用户图片和附件     Audit: 确认、撤销和权限记录       │
└──────────────┬──────────────────────────────────────────────┘
               │ 受限适配器
┌──────────────▼──────────────────────────────────────────────┐
│                    外部服务适配层                            │
│  地图 / 地理编码 / 地点检索 / 路线估算 / 授权内容 / LLM        │
└────────────────────────────────────────────────────────────┘
```

### 3.1 Flutter 负责什么

Flutter 负责：

- 收集队长指令和地图操作；
- 构造带上下文快照的请求；
- 展示队员、任务、结果和决策点；
- 将推荐结果投影为地图标记、卡片和对比状态；
- 将行程草案投影为时间轴、路线和冲突；
- 提交用户确认、拒绝、锁定、修改、撤销和反馈；
- 订阅 Realtime，处理重复事件和断线恢复；
- 提供缓存、空状态、错误和可访问性降级。

Flutter 不负责：

- 直接调用 LLM、内容平台或路线服务；
- 决定推荐排序和硬性约束是否满足；
- 直接写入长期记忆；
- 直接覆盖服务端行程事实；
- 根据事件中的自由文本自行推断业务状态；
- 保存服务端密钥或高权限 Supabase 凭据。

### 3.2 Edge Function 负责什么

Edge Function 负责：

- JWT 认证和资源归属校验；
- 请求体、输入长度、枚举和上下文权限校验；
- 幂等键、速率限制和任务配额；
- 创建任务、步骤和事件；
- 调度 Agent 阶段和受限工具；
- 结构化输出校验、超时、重试和降级；
- 产生推荐、路线、记忆和行程变更提案；
- 校验队长确认和行程版本；
- 以事务方式提交最终结果并发布事件。

Edge Function 不应把进程内存作为任务唯一状态，也不应让模型直接执行任意 SQL、任意 HTTP 或任意用户数据写入。

### 3.3 数据库和 Realtime 负责什么

数据库负责保存：

- 任务和步骤当前状态；
- 结构化 Artifact；
- 事件历史和顺序号；
- 推荐结果和证据引用；
- 行程及其版本；
- 用户记忆和记忆提案；
- 幂等记录、审计记录和反馈。

Realtime 负责：

- 通知任务阶段变化；
- 通知推荐、路线草案和决策点可用；
- 通知行程版本或确认状态变化；
- 推送轻量摘要或资源引用。

完整结果由客户端根据资源 ID 和版本重新读取，不依赖一条事件携带所有数据。

---

## 4. Agent 小队角色设计

### 4.1 角色与领域职责

| `role` | 展示名称示例 | 主要职责 | 主要输出 |
|--------|--------------|----------|----------|
| `result_coordinator` | 队务官 | 拆解任务、调度队员、汇总结果、提出队长决策点 | 任务计划、阶段简报、最终汇报 |
| `intent_interpreter` | 需求分析员 | 将自然语言和界面条件转换为结构化意图 | `IntentArtifact`、`ConstraintArtifact` |
| `map_explorer` | 地图侦察员 | 在限定空间范围内召回地点候选 | `PlaceCandidateArtifact` |
| `preference_advisor` | 口味顾问 | 读取相关记忆、识别匹配信号、提出记忆提案 | `MemoryContextArtifact`、`MemoryProposalArtifact` |
| `content_researcher` | 内容研究员 | 整理公开许可或授权来源的内容和体验信息 | `ContentEvidenceArtifact` |
| `fact_checker` | 事实核验员 | 核验地址、营业时间、价格、重复地点和来源冲突 | `FactCheckArtifact` |
| `recommendation_decider` | 推荐顾问 | 按硬性约束过滤并对候选进行排序和解释 | `RecommendationArtifact` |
| `route_planner` | 路线规划员 | 生成时间顺序、交通段、预算和冲突信息 | `RouteDraftArtifact`、`TripDraftArtifact` |

### 4.3 `AgentPersona`：拟人化角色投影

`AgentPersona` 是前端的表现层对象，不是 Agent 执行权限的来源。

```text
AgentPersona
├── role
├── displayName
├── avatarAsset
├── themeColor
├── accessibilityLabel
├── presenceState
├── currentTaskId
├── latestSummary
└── personaVersion
```

约束如下：

- `role` 使用后端稳定标识，展示名称和人物资源可以替换；
- `avatarAsset` 只引用客户端已发布资源，不允许由模型提供任意文件路径；
- `themeColor` 只能辅助识别，不能作为状态的唯一表达；
- `accessibilityLabel` 必须包含角色名称、职责和当前状态；
- `presenceState` 由 `AgentTask` 和小队状态投影得到，动画不能反向改变任务状态；
- `personaVersion` 用于视觉资源迭代，不影响领域契约和权限。



后端可以保留上述细粒度角色，前端首屏不必同时展示全部角色。建议：

- MVP 首屏展示 4～6 个核心角色；
- 需求分析员、内容研究员和事实核验员可以收进“协作详情”；
- 每个角色至少展示名称、职责、当前状态、当前任务摘要和最近有效产出；
- 角色动画只表达状态，不承载业务真相；
- 角色表情、动作和颜色不能成为唯一的错误或风险提示；
- 开启“减少动态效果”后，必须仍通过文本、图标和语义标签表达状态。

### 4.3 可见汇报与思维链边界

可向队长展示：

- “正在搜索当前区域”；
- “找到 12 个候选地点”；
- “已完成预算筛选”；
- “两处营业时间存在冲突”；
- “该推荐主要匹配本地小店和晚餐时段”；
- “路线草案需要队长确认”；
- 来源、更新时间、置信度和风险提示。

不可向队长展示：

- 原始内部思维链；
- 系统提示词和工具授权策略；
- 未整理的模型内部草稿；
- 其他用户的数据；
- 服务端密钥、内部 URL 或完整原始供应商响应。

“阶段摘要”必须由编排层依据结构化产物生成，不能把模型内部推理原样渲染到前端。

---

## 5. 核心领域对象

### 5.1 `SquadSession`：小队工作会话

`SquadSession` 表示队长围绕一个目标进行的一组 Agent 协作工作，不等同于传统聊天会话。

```text
SquadSession
├── id
├── userId
├── title
├── goal
├── status
├── activeCommandId
├── activeTaskIds
├── selectedPlaceIds
├── mapContext
├── tripContext
├── pendingDecisionIds
├── projectionVersion
└── updatedAt
```

它至少包含：

- 当前工作目标；
- 当前地图视野和筛选条件；
- 当前选中的地点；
- 当前目标行程和行程版本；
- 当前正在执行的任务；
- 等待队长处理的决策点；
- 前端工作区投影版本。

### 5.2 `CaptainCommand`：队长指令

```json
{
  "schemaVersion": 1,
  "clientRequestId": "client-request-uuid",
  "sessionId": "session-uuid",
  "rawText": "在当前区域找三家今晚适合晚餐的本地小店，每人不超过150元",
  "taskType": "discover_places",
  "context": {
    "mapViewport": {
      "center": { "latitude": 39.9042, "longitude": 116.4074 },
      "zoom": 13,
      "bounds": {
        "south": 39.88,
        "west": 116.37,
        "north": 39.93,
        "east": 116.44
      }
    },
    "selectedPlaceIds": [],
    "tripId": null,
    "tripRevision": null
  },
  "constraints": {
    "mealPeriod": "dinner",
    "budget": { "scope": "per_person", "maxMinor": 15000, "currency": "CNY" },
    "placePolicy": { "excludeChains": true },
    "resultLimit": 3
  },
  "memoryPolicy": "propose_only",
  "locale": "zh-CN",
  "clientVersion": "0.1.0"
}
```

约束：

- `rawText` 用于追溯和界面展示，不能作为唯一执行依据；
- `userId` 不由客户端传入，服务端从认证身份取得；
- 地图和行程上下文必须是提交时快照，避免任务执行期间上下文漂移；
- `constraints` 中的硬性条件由确定性规则引擎校验；
- `clientRequestId` 和服务端幂等键共同防止重复创建任务。

### 5.3 `AgentPlan` 与 `AgentStep`：任务图和可执行步骤

`AgentPlan` 表示一次队长指令对应的整体执行图；`AgentTask` 表示某个角色承担的业务工作单元；`AgentStep` 表示任务中的可执行阶段或工具调用。三者不能混为一个状态对象。

```text
AgentPlan
├── id
├── commandId
├── orchestrationVersion
├── taskIds
├── dependencyGraph
├── maxDurationMs
├── maxCost
└── status

AgentStep
├── id
├── taskId
├── kind
├── dependsOn
├── status
├── inputArtifactIds
├── outputArtifactIds
├── toolName
├── attempt
├── leaseExpiresAt
├── startedAt
└── finishedAt
```

编排约束：

- `dependsOn` 只引用同一 `AgentPlan` 内的步骤；
- 只有依赖步骤成功或被允许降级跳过后，步骤才能进入 `running`；
- 并行步骤仍通过数据库分配唯一事件序号；
- 任务或步骤失败时，编排器根据依赖策略决定重试、跳过、部分完成或终止；
- `retrying` 必须记录退避时间和当前尝试次数；
- `cancelling` 后不得创建新的步骤，运行中的外部调用完成后丢弃不可用结果；
- `leaseExpiresAt` 和心跳用于避免 Worker 崩溃后任务永久停留在 `running`；
- 同一 `AgentPlan` 的执行图版本必须持久化，便于回放和审计。

### 5.4 `AgentTask`：Agent 工作单元

```text
AgentTask
├── id
├── sessionId
├── commandId
├── role
├── parentTaskId
├── status
├── progress
├── inputArtifactIds
├── outputArtifactIds
├── userSummary
├── errorCode
├── retryCount
├── startedAt
├── finishedAt
└── version
```

`userSummary` 只能是面向用户的阶段摘要，不能存储内部思维链。任务状态由服务端控制，客户端只能展示和发起允许的命令。

### 5.4 `AgentArtifact`：结构化产物

每个 Artifact 至少包含：

```json
{
  "id": "artifact-uuid",
  "schemaVersion": 1,
  "type": "recommendation_set",
  "taskId": "task-uuid",
  "producer": "recommendation_decider",
  "inputArtifactIds": ["artifact-a", "artifact-b"],
  "payload": {},
  "sourceRefs": ["source-uuid"],
  "confidence": 0.86,
  "warnings": [],
  "freshness": {
    "observedAt": "2026-08-21T10:00:00Z",
    "validUntil": "2026-08-21T18:00:00Z"
  },
  "requiresCaptainApproval": false,
  "createdAt": "2026-08-21T10:00:00Z"
}
```

Artifact 必须：

- 带 `schemaVersion`，允许未来演进；
- 记录生产者和输入产物，支持回放和审计；
- 引用来源，不把无法追溯的自由文本当成事实；
- 明确置信度、警告和新鲜度；
- 标记是否需要队长确认；
- 不写入外部服务的鉴权信息和无关原始响应。

### 5.5 `RecommendationSet`：推荐结果

每个推荐项建议包含：

| 字段 | 说明 |
|------|------|
| `placeId` | 内部地点 ID |
| `rank` | 推荐顺序 |
| `matchSummary` | 面向队长的匹配摘要 |
| `matchedConstraints` | 已满足的条件 |
| `unverifiedConstraints` | 尚未核验的条件 |
| `reasonCodes` | 结构化推荐理由 |
| `evidenceRefs` | 来源引用 |
| `freshness` | 数据更新时间和有效期 |
| `confidence` | 推荐置信度 |
| `riskFlags` | 过期、排队、价格或营业状态风险 |
| `availableActions` | 收藏、比较、加入行程等操作 |

推荐排序必须遵守：

```text
需求提取 → 硬性约束校验 → 候选召回 → 硬性过滤
→ 事实核验 → 推荐排序 → 结果校验 → 用户呈现
```

模型不得为了返回结果而静默放宽预算、忌口、时间窗口或用户明确排除项。

### 5.6 `TripDraft`：行程草案

Agent 生成的路线和行程必须先以草案形式存在，不得直接覆盖已保存行程。

```text
TripDraft
├── tripId
├── baseRevision
├── draftId
├── items
├── routeSegments
├── conflicts
├── budgetSummary
├── durationSummary
├── lockedFields
├── sourceRefs
├── warnings
└── requiresCaptainApproval
```

行程草案的每个变化应能表达：

- 新增、修改、删除和保留的节点；
- 时间、顺序、地点和预算变化；
- 受锁定字段保护的节点；
- 产生的营业时间、路线或预算冲突；
- 需要队长确认的影响范围。

行程核心事实和锁定粒度以 [`行程表数据模型.md`](./行程表数据模型.md) 为准。本文不重新定义 `trips`、`trip_days` 和 `trip_items` 的数据库字段。

### 5.7 `MemoryProposal`：记忆提案

长期记忆分为读取引用和写入提案两部分：

- `MemoryReference`：说明本次推荐使用了哪些已有记忆；
- `MemoryProposal`：说明 Agent 建议新增、修改或删除什么记忆。

推测得到的偏好：

- 只能作为排序信号；
- 不能直接成为硬性排除条件；
- 不能覆盖用户明确表达；
- 默认必须经过队长确认；
- 必须记录推测来源和置信度；
- 必须支持编辑、拒绝和删除。

### 5.8 `DecisionCheckpoint`：队长决策点

需要队长介入时，不应让 Agent 继续猜测。系统创建决策点：

```json
{
  "id": "decision-uuid",
  "sessionId": "session-uuid",
  "kind": "apply_trip_draft",
  "question": "路线草案会调整两个未锁定节点，是否应用？",
  "options": [
    { "id": "apply", "label": "应用草案", "impact": "更新当前行程版本" },
    { "id": "keep_locked", "label": "保留现有安排", "impact": "仅查看冲突" },
    { "id": "cancel", "label": "取消本次调整", "impact": "不修改行程" }
  ],
  "affectedResourceRefs": ["trip-uuid", "trip-item-a", "trip-item-b"],
  "expiresAt": null,
  "status": "pending"
}
```

---

## 6. 状态机设计

### 6.1 小队会话状态

```text
idle
  → receiving_command
  → interpreting
  → dispatching
  → working
  → awaiting_captain_decision
  → applying_decision
  → completed

working → partially_completed
working → timed_out
working → failed
working → cancelled
```

状态含义：

| 状态 | 前端表现 |
|------|----------|
| `idle` | 队员待命，指令栏可用 |
| `receiving_command` | 指令已提交，显示接收确认 |
| `interpreting` | 需求分析员正在整理条件 |
| `dispatching` | 队务官正在分派任务 |
| `working` | 一个或多个队员正在工作 |
| `awaiting_captain_decision` | 显示决策卡，暂停高影响写入 |
| `applying_decision` | 正在执行队长批准的操作 |
| `completed` | 结果可查看和操作 |
| `partially_completed` | 部分结果可用，并说明缺失能力 |
| `timed_out` | 任务超时，提供重试或部分结果 |
| `failed` | 任务失败，提供错误分类和下一步 |
| `cancelled` | 队长或系统取消任务 |

### 6.2 单个 Agent 任务状态

```text
queued → assigned → running → succeeded
                         ├─ waiting_for_dependency
                         ├─ waiting_for_captain
                         ├─ partial
                         ├─ retrying
                         ├─ timed_out
                         ├─ failed
                         └─ cancelled
```

前端可将技术状态转换为角色化文案，但不得隐藏事实：

- `queued`：等待出发；
- `assigned`：已接到任务；
- `running`：正在工作；
- `waiting_for_dependency`：等待其他队员资料；
- `waiting_for_captain`：等待队长决定；
- `succeeded`：已完成汇报；
- `partial`：部分完成，存在信息缺口；
- `failed`：本次工作失败；
- `timed_out`：超过等待时间；
- `cancelled`：任务已取消。

### 6.3 推荐结果状态

```text
draft → generated → displayed
                  ├─ captain_selected
                  ├─ rejected
                  └─ expired

captain_selected → added_to_trip
```

推荐结果未被队长选择前，不能自动成为行程节点。

### 6.4 行程节点状态

行程节点的持久化状态以行程模型为准。Agent 对接层额外要求：

- Agent 生成节点首先属于草案；
- 用户接受后才成为已确认节点；
- 用户锁定地点、时间或顺序后，Agent 不能修改对应字段；
- 用户手动修改后必须记录修改来源为队长；
- 重新规划必须基于当前行程修订号生成新草案；
- 服务端发现修订号冲突时不得覆盖最新版本。

### 6.5 记忆提案状态

```text
proposed → shown_to_captain → accepted
                         ├─ rejected
                         ├─ edited
                         └─ expired
```

禁止以下隐式转换：

```text
Agent 推测 → 正式长期记忆
```

---

## 7. 端到端交互流程

### 7.1 流程一：队长发起区域探索

1. 队长在地图上移动、缩放或框选区域；
2. 队长选择筛选条件或地点；
3. 队长在底部指令栏下达任务；
4. Flutter 创建 `CaptainCommand`，附带地图、行程和筛选快照；
5. Edge Function 验证身份、输入、幂等键、配额和上下文权限；
6. 服务端创建小队会话、指令、任务和初始事件；
7. 需求分析员提取结构化意图和约束；
8. 地图侦察员、口味顾问和内容研究员按依赖关系并行工作；
9. 事实核验员检查地点和来源；
10. 推荐顾问生成推荐集合；
11. 结果汇总员生成阶段简报和最终结果；
12. Flutter 将结果同时投影到地图标记、推荐卡和 Agent 小队面板；
13. 队长收藏、比较、拒绝、查看来源或加入行程；
14. 任何记忆写入或行程修改进入确认流程。

### 7.2 流程二：从候选地点生成一日路线

1. 队长在地图上选择多个地点；
2. 队长下达按午餐、下午茶和晚餐安排路线的指令；
3. 路线规划员读取地点、营业时间、距离、交通方式、停留时长、预算和锁定字段；
4. 生成一个或多个 `TripDraft`；
5. 地图显示顺序编号、路线覆盖层、预计时间和风险；
6. 行程页显示对应日期和时段时间轴；
7. 队长接受、替换、拖动、删除或锁定节点；
8. 用户确认后，Edge Function 以行程修订号为条件提交新版本；
9. 服务端事务成功后，地图、行程页和 Agent 工作区共同更新。

### 7.3 流程三：队长修改后重新规划

1. 队长在行程页拖动未锁定节点或替换地点；
2. Flutter 提交带 `expectedRevision` 的结构化修改命令；
3. 服务端校验行程归属、版本和锁定字段；
4. Agent 仅对允许修改的字段重新规划；
5. 生成差异报告和新的草案；
6. 前端显示新增、删除、时间变化、预算变化和风险变化；
7. 涉及已确认节点或高影响变更时，生成队长决策点；
8. 队长确认后，服务端提交新行程版本；
9. 若版本冲突，前端展示最新版本并允许重新应用或放弃本地修改。

### 7.4 流程四：记忆提案

1. Agent 根据队长明确表达或行为信号发现潜在偏好；
2. 生成 `MemoryProposal`，标明“明确表达”或“系统推测”；
3. 前端在工作区或偏好页显示提案、来源、影响范围和置信度；
4. 队长接受、拒绝、编辑或暂不处理；
5. 只有接受或符合已明确授权的自动记忆策略时，服务端才写入正式记忆；
6. 写入成功后产生 `memory.updated` 事件；
7. 删除或纠正后，后续推荐不得继续使用已删除或被否定的记忆。

---

## 8. Realtime 事件协议

### 8.1 事件信封

所有面向客户端的事件建议使用统一信封：

```json
{
  "eventId": "event-uuid",
  "schemaVersion": 1,
  "eventType": "task.progressed",
  "sessionId": "session-uuid",
  "commandId": "command-uuid",
  "taskId": "task-uuid",
  "sequence": 12,
  "occurredAt": "2026-08-21T10:00:00Z",
  "actor": "orchestrator",
  "visibility": "captain",
  "payload": {}
}
```

字段约束：

- `eventId` 用于去重；
- `sequence` 在同一工作会话内单调递增；
- `occurredAt` 由服务端生成；
- `actor` 只能是 `captain`、`agent`、`orchestrator`、`system` 或 `external_source`；
- `visibility` 控制是否可以进入用户可见事件流；
- `payload` 必须由事件类型对应的 Schema 校验；
- 内部思维链和敏感工具参数不得进入用户可见事件。

### 8.2 客户端命令

建议通过 Edge Function 暴露以下领域命令：

| 命令 | 用途 |
|------|------|
| `submit_captain_command` | 提交探索、推荐、比较或规划任务 |
| `cancel_squad_session` | 取消正在执行的任务 |
| `retry_task` | 对可重试的失败或超时步骤发起受控重试 |
| `select_recommendation` | 记录队长选择的推荐项，不等同于写入行程 |
| `compare_recommendations` | 请求比较两个或多个推荐项 |
| `save_place` | 收藏或取消收藏地点 |
| `reject_recommendation` | 拒绝候选并提交当前任务反馈 |
| `resolve_decision_checkpoint` | 接受、拒绝或选择 Agent 提案 |
| `modify_trip_item` | 直接修改、锁定或解锁未锁定的行程节点 |
| `apply_trip_draft` | 将 Agent 草案应用为新的行程版本 |
| `memory_proposal_decision` | 接受、拒绝或编辑记忆提案 |
| `submit_recommendation_feedback` | 提交喜欢、不感兴趣或不准确反馈 |

MVP 不开放编辑内部任务图、手动指定队员重新分派或修改 Agent 工具权限。命令必须经过权限、输入 Schema、幂等键和资源版本校验，不能让客户端直接更新任意任务状态或业务表。

队长直接编辑与 Agent 草案应用需要区分：

- 队长直接修改未锁定行程项，可以携带 `expectedRevision` 直接提交新的正式行程版本；
- Agent 生成的批量修改必须先进入 `TripDraft`，再由队长确认应用；
- 两者都必须执行用户归属、锁定字段和乐观并发校验。

### 8.3 服务端事件

建议至少支持以下事件：

| 事件 | 作用 | 前端投影 |
|------|------|----------|
| `session.created` | 创建小队会话 | 初始化工作区 |
| `command.accepted` | 指令被接受 | 显示任务已接收 |
| `intent.normalized` | 意图已结构化 | 展示条件摘要 |
| `task.created` | Agent 任务已创建 | 添加角色任务卡 |
| `task.started` | Agent 开始工作 | 更新角色工作状态 |
| `task.progressed` | 阶段摘要或进度变化 | 更新进度和汇报 |
| `task.waiting` | 等待依赖或队长 | 展示阻塞原因 |
| `task.succeeded` | 阶段完成 | 更新角色报告状态 |
| `task.partial` | 阶段部分完成 | 展示信息缺口 |
| `task.failed` | 阶段失败 | 展示错误和降级 |
| `artifact.created` | 产物可用 | 触发资源读取 |
| `recommendation.proposed` | 推荐集合生成 | 更新地图和推荐卡 |
| `map.projection.updated` | 地图投影变化 | 更新标记、聚合或路线 |
| `trip.draft.created` | 行程草案生成 | 更新时间轴草案 |
| `trip.conflict.detected` | 检测到冲突 | 显示冲突卡 |
| `decision.required` | 需要队长决定 | 打开决策卡 |
| `decision.resolved` | 队长已决定 | 更新任务继续状态 |
| `trip.updated` | 行程版本已提交 | 更新地图和行程 |
| `memory.proposed` | 产生记忆提案 | 显示记忆确认卡 |
| `memory.updated` | 记忆已更新 | 更新偏好状态 |
| `session.completed` | 小队任务完成 | 显示完成汇报 |
| `session.partially_completed` | 小队部分完成 | 显示可用结果和缺口 |
| `session.failed` | 小队任务失败 | 展示重试或降级入口 |
| `session.cancelled` | 小队任务取消 | 清理执行状态 |

### 8.4 事件处理规则

#### 顺序缺口

客户端发现 `sequence` 跳跃时：

1. 暂停应用后续事件；
2. 请求当前 `SquadSessionProjection`；
3. 使用服务端快照覆盖本地投影；
4. 从快照版本之后继续处理新事件；
5. 如果事件已过期，直接以当前资源状态为准。

#### 重复事件

客户端使用 `eventId` 去重。重复事件不得重复：

- 添加地点；
- 创建行程节点；
- 写入记忆；
- 弹出同一个决策卡；
- 推进任务状态。

#### Realtime 断线恢复

```text
打开私有 Realtime 订阅
        ↓
读取当前会话快照和资源版本
        ↓
拉取 lastSeenSequence 之后的持久化事件
        ↓
按 eventId 去重、按 sequence 排序
        ↓
应用事件并重新读取最终结果
```

如果服务端不再保留所需事件，客户端必须放弃本地增量推演，重新读取会话、任务、Artifact 和行程当前状态。

#### 事件节流

不发送：

- 每个模型 token；
- 每个内部工具日志；
- 大段原始地点列表；
- 内部思维链。

建议按步骤、阶段或固定时间窗口聚合进度，完整结果保存为 Artifact，由客户端按引用读取。

---

## 9. Flutter 前端对接设计

### 9.1 推荐目录边界

后续实现可沿用现有 `features` 结构，并逐步形成以下边界：

```text
apps/mobile/lib/
├── core/
│   ├── errors/
│   ├── realtime/
│   ├── validation/
│   └── observability/
├── features/
│   ├── explore/
│   │   ├── application/
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   ├── agent/
│   ├── map/
│   ├── trip/
│   └── memory/
└── app/
```

当前 `ExplorePage`、`AgentCommandBar`、`AmapSurface`、`AmapConsent` 和 `TripPage` 的职责应继续保持清晰，不让页面直接承担后端编排。

### 9.2 `SquadWorkspaceState`

探索页和行程页共享一个不可变的工作区投影：

```text
SquadWorkspaceState
├── session
├── command
├── personas
├── tasks
├── briefings
├── recommendations
├── mapProjection
├── tripDraft
├── decisionCheckpoints
├── errors
├── realtimeConnection
└── serverVersion
```

该状态由 Repository 查询和事件 Reducer 更新。页面只负责读取状态和发起命令，不自行猜测结果。

### 9.3 事件 Reducer

Reducer 只执行确定性的投影：

- `task.started` 更新角色状态；
- `task.progressed` 更新阶段摘要；
- `recommendation.proposed` 更新推荐集合；
- `map.projection.updated` 更新地图标记和路线；
- `trip.draft.created` 更新草案时间轴；
- `decision.required` 添加待处理决策；
- `trip.updated` 替换行程版本；
- `session.failed` 更新错误和降级信息。

Reducer 不负责：

- 从汇报文本中猜测地点 ID；
- 根据动画状态推断任务成功；
- 在收到“建议加入行程”时直接写入行程；
- 在收到重复事件时再次执行副作用；
- 绕过服务端把本地草案标记为已保存。

### 9.4 现有组件对接职责

#### `AgentCommandBar`

继续保持“队长指令栏”定位，后续增加：

- `onSubmit` 调用任务创建用例；
- 输入长度、空白和非法状态校验；
- 当前地图、地点和行程上下文标签；
- 执行中的取消入口；
- 重复提交和幂等反馈；
- 将历史展示为任务简报或任务记录，而不是聊天气泡。

#### `AmapSurface`

只负责地图插件适配：

- 初始化和销毁；
- 相机移动；
- 拖拽、缩放和选点；
- 标记、聚合和路线覆盖层渲染；
- 地图错误和手势事件。

业务数据应通过以下方向进入：

```text
MapProjection → MapAdapter → AmapSurface
```

高德 SDK 的类型不应泄漏到 Agent、推荐和行程领域层。

#### `ExplorePage`

负责组合：

- 地图主画布；
- Agent 小队状态浮层或抽屉；
- 当前任务简报；
- 推荐卡和决策卡；
- 底部指令栏。

它不直接调用第三方 API，不直接写 Supabase 表。

#### `TripPage`

负责展示和编辑：

- 行程日和时段；
- 行程节点；
- 地图聚焦；
- 草案与正式版本差异；
- 锁定字段；
- 冲突提示；
- 重新规划和确认入口。

#### `AppShell`

继续保留 `IndexedStack`，确保：

- 切换到行程页时 Agent 任务仍可执行；
- 返回探索页时地图视野和任务面板不丢失；
- 推荐结果可以跨页面同步；
- 工作区状态不依赖单个页面生命周期。

### 9.5 虚拟人物可访问性要求

每个角色卡必须提供：

- 可读的角色名称；
- 角色职责；
- 当前技术状态；
- 当前任务摘要；
- 是否需要队长操作；
- 最近一次有效产出。

以下内容不能只依赖颜色或动画：

- 工作中；
- 失败；
- 阻塞；
- 存在冲突；
- 需要确认。

动画应支持减少动态效果；在无动画状态下，任务进度仍必须清楚可读。

---

## 10. 地图与行程联动规则

### 10.1 地图投影

```text
MapProjection
├── viewport
├── placeMarkers
├── clusters
├── selectedPlaceIds
├── highlightedPlaceIds
├── routeOverlays
├── conflictMarkers
├── focusTaskId
└── mapNotice
```

地图标记至少能够表达：

- 普通候选；
- 推荐排名；
- 当前选中；
- 收藏；
- 已加入草案；
- 已加入正式行程；
- 风险或数据过期；
- 冲突节点。

冲突不得只使用红色表示，必须附带冲突类型、涉及节点、影响范围和可选操作。

### 10.2 行程时间投影

行程页展示同一 `TripPlan` 的时间维度：

```text
TripPlan
├── TripDay
│   ├── TripItem
│   ├── TripItem
│   └── TripItem
└── RouteProjection
    ├── order
    ├── travelSegments
    ├── timeWindows
    └── conflicts
```

地图和行程页必须共享：

- 同一 `placeId`；
- 同一 `tripId`；
- 同一行程修订号；
- 同一节点锁定状态；
- 同一冲突 ID；
- 同一来源任务或草案 ID。

### 10.3 双向操作

地图影响行程：

- 地图选中地点后可加入当前草案；
- 地图选择多个地点后可发起比较或路线规划；
- 地图路线节点操作产生行程修改命令。

行程影响地图：

- 点击时间轴节点，地图聚焦地点；
- 调整时间或顺序，地图刷新路线；
- 锁定节点，地图显示锁定状态；
- 删除或替换节点，地图同步移除或突出对应标记。

所有修改先成为本地编辑状态或服务端草案，正式写入必须经过版本校验和必要的队长确认。

---

## 11. 工具调用边界与安全设计

### 11.1 工具白名单

Agent 只能调用由 Edge Function 明确注册的领域工具，例如：

- `search_places`；
- `get_place_details`；
- `read_user_memory`；
- `search_authorized_content`；
- `verify_place_facts`；
- `estimate_route`；
- `create_memory_proposal`；
- `create_trip_draft`。

工具必须声明：

- 输入 Schema；
- 输出 Schema；
- 是否只读；
- 是否访问用户私有数据；
- 最大调用次数；
- 超时时间；
- 成本或配额；
- 是否产生副作用；
- 是否需要队长确认。

禁止开放：

- 任意 SQL；
- 任意 URL 请求；
- 任意用户 ID 查询；
- 任意 Storage 路径；
- 任意表写入；
- 由模型自行拼接的外部服务凭据。

### 11.2 外部内容是不可信数据

公开或授权内容、评价和地点描述只能作为数据输入，不能作为系统指令。处理时必须：

- 限制长度和字段；
- 区分事实、创作者主观体验和 Agent 推断；
- 保存来源、发布时间和授权范围；
- 不把外部文本直接拼接成高优先级提示；
- 不允许外部内容诱导调用未授权工具；
- 对链接协议、域名和重定向进行限制；
- 在进入推荐或行程前进行结构化校验。

### 11.3 认证、RLS 和数据归属

- 用户身份必须从 Supabase JWT 中取得；
- 忽略客户端传入的 `userId`；
- 所有用户私有资源必须通过 RLS 隔离；
- Agent 任务、Artifact 和事件查询必须验证所属用户；
- 行程写入必须检查 `tripId`、用户归属和修订号；
- 记忆读取和写入必须受用户授权策略控制；
- 客户端不能持有 `service_role`、LLM 密钥或内容平台私有令牌。

### 11.4 幂等、并发和撤销

每个写操作至少使用一种幂等和并发保护：

- 指令使用 `clientRequestId`；
- 行程变更使用 `expectedRevision`；
- 事件使用 `eventId`；
- 记忆提案使用唯一提案 ID；
- 应用草案使用 `draftId` 和 `idempotencyKey`。

服务端发现版本不一致时，返回结构化冲突，不得静默覆盖。任务取消使用服务端状态转换：

```text
running → cancelling → cancelled
```

取消后不得继续启动新的步骤；已完成但未提交的产物可以保留为不可见审计数据，但不能继续产生用户可见完成事件。

### 11.5 日志和可观测性

日志可记录：

- `requestId`、`clientRequestId`、`sessionId`、`taskId`、`stepId`；
- 脱敏用户标识；
- 状态转换、重试、超时和降级；
- 工具类型、延迟和错误分类；
- 行程修订号冲突；
- 记忆和行程确认结果。

禁止记录：

- JWT、API Key 和私有令牌；
- 完整用户隐私指令；
- 未脱敏精确位置；
- 完整外部内容正文；
- 内部思维链；
- 其他用户的资源标识。

---

## 12. 异常与降级矩阵

| 场景 | 服务端处理 | 前端处理 |
|------|------------|----------|
| 未登录 | 拒绝创建任务或读取私有资源 | 引导登录，不显示私有数据 |
| 请求格式错误 | 返回字段级错误，不创建任务 | 标记具体输入问题 |
| 重复指令 | 返回原任务引用 | 不重复显示任务 |
| 频率超限 | 返回限流错误和重试建议 | 禁止循环重试 |
| 单个 Agent 超时 | 有限重试或标记部分完成 | 显示已完成部分和缺失能力 |
| 地点检索不可用 | 使用合规缓存或返回空候选 | 允许查看已有结果，说明数据来源 |
| 路线服务不可用 | 保留地点顺序，不生成准确导航承诺 | 显示“无法计算准确到达时间” |
| 内容来源不可用 | 去除该来源影响，继续使用基础数据 | 标注内容研究未完成 |
| 事实信息冲突 | 标记冲突，不猜测补全 | 展示来源和冲突原因 |
| Realtime 断线 | 持续持久化任务 | 重连、补齐事件或读取快照 |
| 事件序号跳跃 | 提供当前会话快照 | 以快照覆盖本地投影 |
| 行程版本冲突 | 返回最新修订号和差异 | 让队长选择重新应用或放弃 |
| 预算或时间无法满足 | 不静默放宽硬性约束 | 提供明确的放宽选项决策卡 |
| 记忆不可用 | 使用显式输入继续，不假设无偏好 | 标注个性化能力暂不可用 |
| 任务取消 | 阻止新步骤，完成状态转换 | 清理执行态，保留可查看结果 |

空结果必须区分：

- 没有符合硬性条件的地点；
- 当前区域无数据；
- 数据源暂不可用；
- 条件过严；
- 地图视野或位置无效。

不能一律显示“暂未找到”。

---

## 13. 分阶段落地建议

### 阶段一：指令与任务骨架

目标：

- 指令栏提交结构化请求；
- 创建会话、指令、任务和状态事件；
- 用静态头像、文本状态和任务卡验证非聊天式交互；
- 支持取消、重复提交和基础错误。

暂不要求复杂人物动画和全部 Agent 角色。

### 阶段二：小队状态工作区

目标：

- 角色卡和职责词典；
- 任务状态、阶段摘要和阻塞状态；
- 决策卡；
- Realtime 连接、去重和断线恢复；
- 减少动态效果和无障碍语义。

### 阶段三：地图推荐闭环

目标：

- 地点候选和推荐结果契约；
- 推荐结果投影到地图和卡片；
- 收藏、比较、反馈和加入行程；
- 来源、更新时间、置信度和风险提示。

### 阶段四：行程草案和版本化

目标：

- 生成 `TripDraft`；
- 地图路线和行程时间轴双向联动；
- 支持拖动、替换、删除和锁定；
- 支持冲突检测、确认、版本冲突和撤销。

### 阶段五：记忆与内容研究

目标：

- 读取相关记忆；
- 展示记忆提案；
- 接入公开许可或授权内容；
- 对事实、体验和推断进行来源化展示；
- 建立反馈到推荐排序的闭环。

建议每个阶段先稳定契约和测试，再增加新的 Agent 角色，避免前端先绑定不稳定的人物数量或自然语言格式。

---

## 14. 对接验收标准

### 14.1 非聊天式交互

- **AC-AS-001**：进入探索页后，用户看到地图主工作区、Agent 小队入口和底部指令栏，不以聊天消息列表作为默认主界面。
- **AC-AS-002**：提交自然语言需求后，系统创建结构化队长指令和 Agent 任务，而不是只保存一条聊天消息。
- **AC-AS-003**：任务执行期间，用户能看到参与角色、当前阶段、阶段摘要和下一步动作。
- **AC-AS-004**：推荐结果同时出现在地图投影和可操作结果卡中。
- **AC-AS-005**：切换到行程页后，任务继续执行，返回探索页仍能看到最新状态。

### 14.2 队长控制和确认

- **AC-AS-006**：Agent 不能在未确认时直接写入推测记忆。
- **AC-AS-007**：Agent 不能自动覆盖用户锁定的地点、时间或顺序字段。
- **AC-AS-008**：预算、时间或忌口无法满足时，系统展示明确的放宽选项，不静默放宽。
- **AC-AS-009**：应用行程草案前，系统展示变更差异、影响范围、来源和风险。
- **AC-AS-010**：用户可以拒绝、撤销或重新规划 Agent 结果。

### 14.3 虚拟人物形象

- **AC-AS-011**：每个展示角色具有稳定名称、职责、头像、状态和最近一次有效汇报。
- **AC-AS-012**：角色状态变化时，人物表现、文本状态和语义标签保持一致。
- **AC-AS-013**：减少动态效果后，用户仍可通过文本和图标理解角色状态。
- **AC-AS-014**：人物的警告表情不是唯一风险提示，页面同时展示具体原因和操作入口。

### 14.4 事件一致性

- **AC-AS-015**：重复 Realtime 事件不会造成重复地点、行程节点或记忆写入。
- **AC-AS-016**：发现事件序号缺口后，客户端会读取服务端快照，不继续盲目应用后续事件。
- **AC-AS-017**：Realtime 断线重连后，任务、推荐、地图和行程投影与服务端状态一致。
- **AC-AS-018**：任务完成事件只在最终结果持久化成功后发送。
- **AC-AS-019**：客户端不能仅凭本地 loading 状态判断 Agent 任务已经完成。

### 14.5 地图和行程联动

- **AC-AS-020**：地图选中地点后，推荐卡或行程节点同步进入选中态。
- **AC-AS-021**：行程时间轴选中节点后，地图聚焦同一地点 ID。
- **AC-AS-022**：路线草案在地图和行程页使用同一草案 ID、行程 ID 和版本。
- **AC-AS-023**：行程节点锁定后，重新规划不会修改被锁定字段。
- **AC-AS-024**：营业时间、时间重叠、路线过长和预算超限以结构化冲突呈现。

### 14.6 解释、安全和降级

- **AC-AS-025**：推荐结果显示匹配理由、来源、更新时间、置信度和不确定性。
- **AC-AS-026**：系统推测的偏好明确标记为推测，不能冒充用户明确表达。
- **AC-AS-027**：外部内容中的事实、主观体验和 Agent 推断分开呈现。
- **AC-AS-028**：任务失败或超时时，页面显示已完成部分、缺失能力和可执行的重试或降级操作。
- **AC-AS-029**：无权访问其他用户的行程、记忆、任务和事件。
- **AC-AS-030**：内部思维链、系统提示词和服务端密钥不会进入客户端事件或用户界面。

---

## 15. 待确认事项

以下问题不阻塞本文作为第一版对接基线，但在进入实现前需要形成明确决策：

| 编号 | 问题 | 建议默认值 |
|------|------|------------|
| OQ-AS-001 | MVP 首屏展示多少个 Agent 角色 | 展示 4～6 个，其他角色收进协作详情 |
| OQ-AS-002 | 一个小队会话是否允许多个并行任务 | 允许，但由编排器限制并发和资源预算 |
| OQ-AS-003 | Agent 任务是同步 Edge Function 还是异步 Worker | MVP 先采用有界任务；路线和多来源研究再拆分 Worker |
| OQ-AS-004 | 事件保留多久 | 至少覆盖任务结果可追溯周期，具体由数据保留策略确定 |
| OQ-AS-005 | 是否允许队长暂停后重新分派单个队员 | MVP 只支持取消和重新提交，暂不开放内部任务图编辑 |
| OQ-AS-006 | 虚拟人物的最终视觉风格 | 先使用静态或轻量 2D 形象，避免绑定 3D 引擎 |
| OQ-AS-007 | 记忆自动写入范围 | 默认 `propose_only`，由用户设置逐步开放 |
| OQ-AS-008 | 地图服务适配层的最终实现 | 保留 Provider Adapter，不在业务层绑定单一供应商 |

---

## 16. 相关文档与实现边界

- [`CLAUDE.md`](../../CLAUDE.md)：项目目标、技术栈、目录职责、安全和文档规范；
- [`docs/项目计划书.md`](../项目计划书.md)：产品范围、多 Agent 职责、地图和行程目标；
- [`docs/develop/1.前端基础结构开发.md`](../develop/1.前端基础结构开发.md)：当前三页入口、地图主区域和底部 Agent 指令栏；
- [`docs/开发日志.md`](../开发日志.md)：当前实际实现状态、地图接入遗留问题和行程数据模型设计记录；
- [`行程表数据模型.md`](./行程表数据模型.md)：`trips`、`trip_days`、`trip_items` 的持久化模型与不变量；
- `packages/contracts`：后续承载本文定义的跨端协议和 Schema；
- `packages/domain`：后续承载状态机、约束和纯领域逻辑；
- `supabase/functions/agent`：后续承载任务编排和工具网关；
- `supabase/migrations`、`supabase/policies`：后续承载任务、事件、记忆、行程扩展和 RLS。

本文与行程表数据模型的关系是：

- 本文定义 Agent 如何生成、展示、确认和应用行程草案；
- 行程表数据模型定义行程核心表、字段、锁定和持久化不变量；
- 两者通过 `tripId`、`tripItemId`、`revision`、`draftId` 和 `sourceAgentTaskId` 等引用衔接；
- 本文不把路线、冲突和 Agent 状态塞入行程核心事实表。

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-08-21 | 初始版本：定义队长指挥 Agent 小队与 Flutter 前端的交互模型、任务编排、结构化事件、Realtime、工具边界、地图/行程联动和验收标准 |
