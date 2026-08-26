# 探索页悬浮像素 Agent 小人与气泡交互落地设计

> 文档状态：规划中，作为后续编码与验证基线
>
> 适用范围：Flutter 探索页（P-MAP）中的悬浮 Agent 小人、结构化气泡和地图覆盖层
>
> 当前基线日期：2026-08-26

## 1. 文档目的与事实源

本文将“探索页核心地图区域悬浮像素小人 + 气泡交互”细化为可编码、可测试的实现方案，覆盖：

- Flame 像素小人的显示、收起、隐藏和恢复；
- 小人与气泡同时可见的布局不变量；
- 回答、地点/内容列表、单选、多选、带输入框疑问和决策卡；
- 地图、Agent、地点详情和行程面板之间的层级与交互边界；
- Flutter、Flame、高德地图和 Agent 工作区的职责分工；
- 状态、事件、命令、可访问性、性能、降级和验收标准。

本文不重新定义已有事实源：

- 产品目标与 MVP 范围以 [`docs/项目计划书.md`](../项目计划书.md) 为准；
- Agent 角色、任务、Artifact、Realtime 和确认边界以 [`docs/architechture/Agent小队与Flutter前端交互对接设计.md`](../architechture/Agent小队与Flutter前端交互对接设计.md) 为准；
- `trips`、`trip_days`、`trip_items` 的持久化字段、RLS、revision 和写入不变量以 [`docs/architechture/行程表数据模型.md`](../architechture/行程表数据模型.md) 为准。

本文只定义本功能新增的表现层、交互层和落地边界。当前 Flame、气泡协议、Agent 工作区和真实 Agent 编排尚未实现，本文中的“应”“支持”表示目标方案，不代表当前已经交付。

## 2. 当前项目基线

### 2.1 已有能力

当前仓库已经具备以下可复用基础：

- `ExplorePage` 使用 `Column → Expanded → Stack`，地图占据主要区域；
- `AmapSurface` 封装高德原生地图、Marker、Polyline、相机和手势；
- 探索页已有地图状态提示、搜索中 chip 和地点详情面板；
- `AgentCommandBar` 固定在地图区域下方，负责队长输入；
- 地点检索、地点详情、加入行程、行程路线小地图和全屏路线页已有客户端代码；
- `AppShell` 使用 `IndexedStack` 保留探索页、行程页和“我的”页状态；
- Agent 架构文档已经定义 `AgentPersona`、`SquadWorkspaceState`、`DecisionCheckpoint`、Artifact 和事件映射。

关键实现位置：

- `apps/mobile/lib/features/explore/explore_page.dart`
- `apps/mobile/lib/features/explore/amap_surface.dart`
- `apps/mobile/lib/features/explore/agent_command_bar.dart`
- `apps/mobile/lib/features/places/place_detail_sheet.dart`
- `apps/mobile/lib/app/navigation/app_shell.dart`
- `apps/mobile/lib/app/theme/design_tokens.dart`

### 2.2 尚未实现

- `pubspec.yaml` 尚未引入 Flame；
- 尚无像素 Agent 资源目录和资源白名单；
- 尚无 `AgentOverlay`、气泡渲染器和收起/隐藏状态；
- 尚无 `SquadWorkspaceState` 的 Flutter 实现、Agent Repository 或事件 Reducer；
- Agent Edge Function 仍是健康检查占位；
- 尚无气泡结构化 Schema、输入型决策点契约和气泡命令；
- 尚无 Agent Realtime、断线恢复和决策卡闭环。

当前 `AgentCommandBar` 提交的内容仍主要被当作地点关键词检索，不能把它视为已完成的 Agent 对话入口。

## 3. 产品决策

### 3.1 核心空间关系

像素小人的活动范围是探索页地图区域的核心视觉区域，悬浮在真实地图上方。它是 Agent 工作区的视觉入口，不是高德地图底图的一部分，也不是地理事实来源。

```text
探索页
├── 高德真实地图：道路、文字、地点位置和路线事实
├── 地图业务覆盖层：地点标记、选中态、路线节点和风险标识
├── AgentOverlay：像素小人、气泡和恢复入口
└── Flutter 业务 UI：详情、状态、来源、确认和底部指令栏
```

真实地图继续承担空间事实；像素小人和气泡负责表达角色、任务阶段、解释和队长操作。

### 3.2 气泡不是传统聊天窗口

气泡是结构化的任务交互表面，不是自由文本聊天消息列表。它可以显示回答、阶段汇报、推荐列表、选项、疑问和决策，但每一项内容都必须有明确类型、数据来源和可执行动作。

气泡可以表达：

- “我在当前区域找到 8 家符合条件的地点”；
- “以下 3 家的营业时间还没有交叉核验”；
- “请选择优先距离短，还是优先本地特色”；
- “请补充可接受的步行时间”；
- “这份行程草案会调整两个未锁定节点，是否应用”。

气泡不能承载：

- 未整理的内部思维链；
- 随意解释出来的地点 ID、价格或营业状态；
- 任意 Flutter 操作指令；
- 服务端密钥、内部 URL 或其他用户数据。

### 3.3 高德底图不做全屏像素化

MVP 不对高德原生平台视图做全屏滤镜、截图离屏处理、瓦片重绘或未经授权的预处理。Flame 只绘制透明的像素角色和少量应用自有装饰，不能接管地图渲染。

不得遮挡、裁剪或重绘高德版权、归属、道路文字和必要地图信息。若未来建设完整像素地图，应使用自有或明确授权的数据源，作为独立 `PixelMapMode`，而不是改造高德在线底图。

## 4. 总体架构

```text
Supabase / Agent 编排 / Realtime
                ↓
Workspace Repository + Event Reducer
                ↓
SquadWorkspaceState
        ┌───────┴────────┐
        ↓                ↓
AgentOverlayModel   AgentVisualState
        ↓                ↓
Flutter 气泡组件      Flame GameWidget
        └───────┬────────┘
                ↓
探索页地图区域 Stack
        ┌───────┼────────┐
        ↓       ↓        ↓
AmapSurface  地图业务层  AgentOverlay
                ↓
       PlaceDetailSheet / 指令栏 / 行程面板
```

### 4.1 Flutter 负责

- 读取工作区快照并应用确定性事件 Reducer；
- 生成 `AgentOverlayModel` 和布局约束；
- 渲染气泡文本、列表、选项、输入框、决策卡和错误；
- 管理焦点、键盘、滚动、语义树和辅助技术；
- 处理收起、隐藏、恢复和待处理标识；
- 将气泡动作转换为结构化命令；
- 将结构化地点引用投影到 Marker、详情和行程操作；
- 处理错误、过期、重复提交、断线和快照恢复。

### 4.2 Flame 负责

- 像素小人的 Sprite、Sprite Sheet 和有限帧动画；
- 待命、工作、等待、完成和失败等视觉状态；
- 资源加载、缓存、版本和生命周期；
- 根据 `AgentVisualState` 暂停、恢复或切换动画；
- 将明确的小人点击事件转交 Flutter。

Flame 不负责：

- Agent 编排或网络请求；
- Supabase、Realtime、地点仓库或行程仓库；
- 气泡文本、列表、表单和决策逻辑；
- 地点坐标转换、地图相机和路线事实；
- 判断任务成功、失败或是否写入业务数据；
- 执行服务端下发的脚本、文件路径或任意绘制指令。

### 4.3 `AmapSurface` 负责

`AmapSurface` 继续保持地图适配层职责：

- 高德隐私同意后的初始化；
- 原生地图平台视图；
- Marker、Polyline、相机和手势；
- 地图点击和地图生命周期。

AgentOverlay 应由 `ExplorePage` 或后续工作区容器放在地图区域的 `Stack` 中，不能把气泡和 Agent 业务塞入 `AmapSurface`。

## 5. 页面布局与可见性

### 5.1 推荐组件树

```text
ExplorePage
└── Column
    ├── Expanded
    │   └── Stack
    │       ├── Positioned.fill: AmapSurface
    │       ├── MapProjectionOverlay
    │       ├── AgentMapOverlay
    │       │   ├── AgentFlameView
    │       │   ├── AgentBubblePanel
    │       │   └── AgentRestoreButton
    │       ├── SearchingChip / MapNotice
    │       └── PlaceDetailSheet
    └── AgentCommandBar
```

`AgentMapOverlay` 只覆盖地图区域，不覆盖底部 `AgentCommandBar`。探索页仍保持地图主工作区和底部指令栏固定的现有布局，不改造成滚动聊天页面。

### 5.2 三种显示状态

#### `expanded`

- 显示完整像素小人；
- 显示当前气泡；
- 气泡标题、正文和主要动作可操作；
- 小人与气泡在同一视口内同时清晰可见；
- 有待处理问题时，默认保持展开，除非用户主动收起。

#### `collapsed`

- 保留小人；
- 隐藏或压缩气泡正文；
- 显示未读数、待确认数或可读状态徽标；
- 点击小人重新展开当前气泡；
- 不取消任务，也不删除气泡内容。

#### `hidden`

- 隐藏小人和气泡；
- 地图获得更大可视空间；
- 保留“打开 Agent 助手”的低干扰恢复入口；
- 待确认决策、未读结果和输入问题不能静默丢失；
- 隐藏只改变本地表现状态，不暂停服务端任务。

`visibility` 属于表现层状态，不写入 Agent 任务事实。是否持久化为用户偏好，见待确认事项。

### 5.3 小人与气泡同时可见不变量

在 `expanded` 状态下必须满足：

1. 小人本体完整位于地图区域内；
2. 气泡标题、正文和当前主要操作不被裁剪；
3. 气泡不能覆盖小人；
4. 小人和气泡的视觉关系明确，气泡箭头或布局方向指向小人；
5. 键盘弹出、文字放大、横竖屏变化和小屏设备下仍成立；
6. 内容过长时只滚动气泡内部，不让整个地图区域失去操作能力；
7. 气泡不能覆盖底部指令栏、地点详情主要操作和高德版权/归属保留区。

“同时可见”不要求历史气泡全部展开，但要求当前交互单元无需在小人和气泡之间来回切换才能理解和操作。

### 5.4 锚点与避让

MVP 使用有限的屏幕锚点，不允许模型下发屏幕坐标，也不实现沿真实地图路径移动的小人。

默认候选顺序：

```text
右上 → 左上 → 右侧中部 → 左侧中部 →
地图下方但高于底部栏 → 最小遮挡回退位置
```

布局算法将以下区域视为障碍矩形：

- `MediaQuery.padding` 和系统安全区；
- 底部 `AgentCommandBar` 的上边界；
- 搜索中 chip；
- `_MapNotice`；
- `PlaceDetailSheet`；
- 高德版权、归属和原生控件保留区；
- 系统键盘覆盖区。

布局流程：

1. 获取地图区域尺寸和安全区；
2. 获取当前浮层边界；
3. 为小人和气泡生成候选锚点；
4. 依次测试与障碍矩形的相交关系；
5. 选择位于地图区域内且遮挡最少的位置；
6. 根据小人所在侧决定气泡向左或向右展开；
7. 将气泡限制在可见边界内，并为超长内容提供内部滚动；
8. 键盘、详情面板、文字缩放或地图尺寸变化时重新布局。

气泡过大时应优先压缩内容或切换为内部滚动/分页，不应把小人移出视口，也不应扩大成覆盖全屏的不可解释弹窗。

### 5.5 尺寸与交互面积

最终数值应沉淀为 `AgentOverlayTokens`，禁止散落在页面中。初始设计基线：

- 小人主要点击区域不小于 48dp；
- 气泡距离地图区域边缘至少 8–16dp；
- 气泡最大宽度不超过地图区域宽度约 90%；
- 气泡最大高度约为可用地图区域的 40%–50%；
- 列表项、选项和提交按钮满足移动端最小触控面积；
- 标题、当前状态和主要动作不放入不可见的滚动区域；
- 小人使用固定逻辑像素尺寸和整数倍缩放，Flutter 正文不强制像素化。

## 6. 气泡内容模型

### 6.1 `AgentBubble`

```text
AgentBubble
├── id
├── schemaVersion
├── sessionId
├── commandId
├── taskId
├── producerRole
├── sequence
├── kind
├── title
├── body
├── items
├── choices
├── input
├── actions
├── sourceRefs
├── freshness
├── confidence
├── riskFlags
├── requiresCaptainAction
├── expiresAt
├── submissionId
└── status
```

约束：

- `id` 用于去重；
- `sessionId`、`taskId` 用于资源归属校验；
- `sequence` 和 `version` 防止旧气泡覆盖新状态；
- `kind` 必须是白名单枚举；
- `payload` 根据 `kind` 使用对应 Schema 校验；
- `actions` 只能引用已注册的命令类型；
- `sourceRefs`、`freshness`、`confidence` 和 `riskFlags` 按内容类型展示；
- `expiresAt` 到期后禁止继续执行高影响动作；
- 气泡只保存用户可见摘要和结构化内容，不保存思维链和敏感工具参数。

### 6.2 支持的气泡类型

| `kind` | 用途 | 内容形式 |
|---|---|---|
| `announcement` | 简短通知 | 文本和状态图标 |
| `answer` | 阶段汇报或结果总结 | 文本、可折叠详情 |
| `place_list` | 地点候选 | 结构化地点列表和操作 |
| `content_list` | 授权内容候选 | 内容列表、来源和时间 |
| `single_choice` | 单选问题 | 选项和提交 |
| `multi_choice` | 多选问题 | 复选项、数量约束和提交 |
| `input_question` | 自由输入问题 | 输入框、校验和提交 |
| `decision` | 高影响操作确认 | 差异、风险、确认/拒绝/编辑 |
| `progress` | 阶段进度 | 状态文本和摘要 |
| `error` | 错误和降级 | 原因、已完成部分和下一步 |

未知类型必须安全降级为普通错误/通知，不执行未知动作。

### 6.3 地点列表

地点列表不能由气泡自由文本解析，必须引用结构化地点 ID：

```text
BubblePlaceItem
├── placeId
├── title
├── subtitle
├── rank
├── matchSummary
├── reasonCodes
├── matchedConstraints
├── unverifiedConstraints
├── sourceRefs
├── freshness
├── confidence
├── riskFlags
└── availableActions
```

点击地点后，Flutter 根据 `placeId`：

- 高亮正确的地图 Marker；
- 打开或更新 `PlaceDetailSheet`；
- 支持收藏、比较或加入行程；
- 不从地点名称、摘要或气泡位置猜测地点。

### 6.4 内容列表

```text
BubbleContentItem
├── contentId
├── title
├── summary
├── sourceName
├── sourceUrl
├── publishedAt
├── freshness
├── evidenceType
└── availableActions
```

外部内容的事实、创作者主观体验和 Agent 推断必须分开标识。像素化表现不能成为规避外部内容授权的方式。

### 6.5 选项

```text
BubbleChoice
├── id
├── label
├── description
├── impact
├── selected
├── disabled
└── disabledReason
```

多选模型必须声明最少选择数、最多选择数、是否允许全不选、选项是否过期以及提交后是否锁定。客户端负责即时校验，服务端必须再次校验。

### 6.6 输入型疑问

现有 `DecisionCheckpoint` 主要定义问题和选项，尚未覆盖自由输入。实现前需扩展为结构化输入模式：

```text
BubbleInputSpec
├── key
├── prompt
├── placeholder
├── initialValue
├── valueType: text | number | date | time
├── keyboardType
├── minLength
├── maxLength
├── minValue
├── maxValue
├── enumValues
├── required
└── validationMessage
```

输入型问题的回答仍然通过结构化的 `resolve_decision_checkpoint` 或专用命令提交，不把输入伪装成聊天消息。客户端校验不能替代服务端校验。

## 7. 气泡动作与命令

### 7.1 动作类型

建议支持：

```text
open_place
open_content
select_bubble_options
submit_bubble_input
resolve_decision_checkpoint
retry_task
cancel_squad_session
dismiss_bubble
expand_agent_overlay
collapse_agent_overlay
hide_agent_overlay
```

`expand/collapse/hide` 是本地表现动作；其余动作根据权限和资源状态发起结构化命令。

### 7.2 统一命令字段

```text
BubbleCommand
├── schemaVersion
├── clientRequestId
├── sessionId
├── bubbleId
├── taskId
├── expectedSequence
├── action
├── payload
└── locale
```

必须满足：

- `clientRequestId` 幂等；
- `bubbleId`、`taskId` 和 `sessionId` 做资源归属校验；
- `expectedSequence` 防止过期提交；
- 气泡过期后禁止高影响写入，要求刷新；
- 重复点击不创建重复任务、行程节点或记忆；
- 行程草案、记忆提案和高影响操作仍由 `DecisionCheckpoint`、服务端权限和 revision 校验控制。

## 8. Agent 状态与 Flame 映射

### 8.1 表现层模型

```text
AgentVisualState
├── role
├── displayName
├── spriteKey
├── presenceState
├── animationMode
├── motionPolicy
├── pixelScale
├── accessibilitySummary
└── resourceVersion
```

数据流：

```text
AgentTask / AgentPersona
        ↓
AgentVisualState
        ↓
AgentOverlayModel
        ↓
Flame GameWidget + Flutter AgentBubblePanel
```

### 8.2 状态映射

| 业务状态 | 小人表现 | 气泡表现 |
|---|---|---|
| `queued` | 待命静态帧 | 已收到任务，等待开始 |
| `running` | 轻量工作循环 | `progress` 或阶段摘要 |
| `waiting` | 停止动作、等待标识 | `question`/`input_question`/等待原因 |
| `succeeded` | 一次性完成反馈后回待命 | `answer`、`place_list` 或结果摘要 |
| `partial` | 部分完成标识 | 已完成部分、缺口和下一步 |
| `failed` | 错误静态帧 | `error`、重试或降级入口 |
| `timed_out` | 超时静态帧 | 超时原因和重试入口 |
| `cancelled` | 回待命或离场帧 | 取消原因和重新提交入口 |

角色动画只表达任务状态，不能改变任务状态。动画结束不能触发写入，也不能作为任务成功的依据。

### 8.3 主导角色与角色数量

MVP 首先显示一个当前主导角色或队务官，其他角色放入气泡详情或协作详情。后续再扩展到 4–6 个角色，但仍使用一个 `AgentMapOverlay` 管理统一布局，避免多个独立全屏覆盖层竞争地图手势和空间。

## 9. 地图、地点详情和行程联动

### 9.1 地图联动

气泡中的地点和路线结果必须引用结构化 Artifact、`placeId`、路线数据和版本信息。客户端不能根据阶段摘要猜地点 ID，也不能根据小人位置推断坐标。

地图业务投影仍负责：

- Marker 和选中态；
- 推荐排名和风险标识；
- 路线节点和 Polyline；
- 地图与气泡的选中同步。

### 9.2 地点详情冲突处理

当用户点击 Marker 打开 `PlaceDetailSheet`：

- 地点详情优先保证完整信息、来源和操作按钮；
- Agent 气泡可压缩为摘要或暂时收起，但不能丢失未处理问题；
- 详情关闭后恢复气泡原状态；
- 新决策通过恢复入口或待处理徽标提示，不自动覆盖用户当前详情操作。

### 9.3 行程草案确认

气泡可以展示 `TripDraft`，但必须：

1. 展示拟修改节点、时间、预算、来源和风险；
2. 标出用户锁定字段；
3. 提供“应用草案”“编辑”“拒绝”；
4. 通过 `apply_trip_draft`、用户归属和 `expectedRevision` 校验；
5. 成功后重新读取最新行程版本，再刷新地图和时间轴；
6. 版本冲突、不可写和过期均以文本错误呈现。

本文不改变当前行程节点状态约束。行程取消与节点状态不是同一概念，不设计已被当前最终迁移移除的节点 `cancelled` 流程。

## 10. 地图手势与命中测试

默认规则：

- Flame 透明区域不参与命中测试；
- 气泡以外区域仍交给高德地图处理拖拽、双指缩放和地图点击；
- 只有小人按钮、气泡按钮、列表项、选项和输入框开启命中测试；
- 不使用全屏透明 `GestureDetector` 包住地图；
- 气泡展开时，气泡内部控件优先接收点击；
- 地图空白点击可以按现有规则关闭地点详情，但不得误清除输入内容或待确认决策；
- 小地图继续沿用现有 `gesturesEnabled=false`、点击进入全屏的策略。

高德是原生平台视图。Android 和 iOS 必须分别验证 Z-order、触摸穿透、Marker 点击、地图手势和键盘焦点，不能只依赖普通 Widget 测试。

## 11. 生命周期、性能与资源

### 11.1 Flame 生命周期

由于 `AppShell` 使用 `IndexedStack`，离开探索页后 Widget 仍然存在，不能只依赖 `dispose` 停止动画。

| 条件 | Flame 行为 |
|---|---|
| 探索页可见、应用前台 | 正常或受限播放 |
| 探索页不可见但被保活 | 暂停更新和非必要绘制 |
| 应用进入后台 | 暂停动画和输入监听 |
| `hidden` | 暂停非必要动画，保留恢复入口 |
| 减少动态效果 | 静态帧或极少量过渡 |
| 资源加载失败 | Flutter 静态头像和气泡回退 |
| 无未读且任务结束 | 降低刷新频率或静态待命 |

任务执行由应用层和服务端负责，不因 Flame 暂停而暂停。

### 11.2 资源策略

建议资源目录：

```text
apps/mobile/assets/agent_pixel/
├── agents/
├── markers/
├── effects/
└── ui/
```

要求：

- `avatarAsset` 或 `spriteKey` 只能引用客户端资源白名单；
- Agent 不能下发任意文件路径、远程图片或动画脚本；
- 使用固定基础分辨率、最近邻采样和整数倍缩放；
- 优先使用 Sprite Sheet，限制纹理数量和尺寸；
- 每项资源记录来源、许可证、修改权、商用权、署名要求和版本；
- 资源失败时回退到静态 Flutter 图标或角色占位；
- 不可见页面、后台和隐藏态释放或暂停非必要资源。

### 11.3 渲染与事件节流

- MVP 使用一个轻量 Flame `GameWidget` 或单一组件树；
- 不为每个角色和气泡创建独立 ticker；
- Realtime 事件按阶段或时间窗口聚合，不按每个模型 token 重建；
- 不在每帧重建全部 Marker、Polyline 或 Flame 实体；
- 地点和内容完整结果通过 Artifact/资源引用读取；
- 列表使用惰性构建；
- 不对高德底图使用全屏滤镜、截图或离屏像素化。

## 12. 可访问性与可用性

### 12.1 小人语义

小人必须有包含上下文的语义描述：

```text
[角色名称]，[职责]，[当前状态]。
[当前任务摘要]。
[是否需要队长操作]。
```

例如：

> 队务官，负责协调 Agent 小队，当前正在整理需求。已收到你的探索指令，等待下一步结果。

收起和隐藏后：

- `collapsed` 的小人仍可读出当前状态和未读数量；
- `hidden` 的恢复入口必须有“打开 Agent 助手”等明确语义；
- 不得只提供“点击像素小人”这种无上下文标签。

### 12.2 气泡语义与焦点

- 标题、正文、状态、来源和主要操作有稳定朗读顺序；
- 展开气泡时焦点进入标题或第一个可操作控件；
- 收起/关闭后焦点回到小人或恢复入口；
- 新气泡出现时使用可访问状态更新，不强制打断用户正在进行的输入；
- 错误信息与对应输入控件关联；
- 气泡过期时明确说明需要刷新；
- 所有关键操作存在于 Flutter 语义树，不只绘制在 Flame 画布中。

### 12.3 控件与状态

- 单选使用 `RadioListTile` 或等价语义控件；
- 多选使用 `CheckboxListTile`；
- 输入使用标准 `TextField`，带 label、hint、长度限制和错误信息；
- 地点项展示名称、类别、匹配理由和可用动作；
- 内容项展示标题、来源和更新时间；
- 决策卡展示问题、影响范围、来源、风险和结果动作。

工作中、等待、失败、超时、冲突和需要确认等状态不能只依赖颜色、表情或动画，必须同时有文本、图标或语义标签。

### 12.4 键盘、文字缩放和减少动态效果

至少验证：

- TalkBack；
- VoiceOver；
- 键盘 Tab 和方向键；
- 文本缩放 200%；
- 高对比度；
- 系统减少动态效果；
- 小屏和横屏；
- 输入法弹出后的布局。

减少动态效果时停止循环待机、位移动画和粒子效果，直接显示静态小人、气泡和状态文本。功能不能因关闭动画而缺失。

## 13. 错误、降级与安全

| 场景 | 目标行为 |
|---|---|
| Flame 资源缺失 | 使用 Flutter 静态头像，气泡继续可用 |
| Flame 初始化失败 | 保留气泡、文本状态和操作 |
| Agent 服务不可用 | 错误气泡，显示重试或回到底部指令栏 |
| Realtime 断线 | 显示恢复状态，重连后读取工作区快照 |
| 事件序号跳跃 | 暂停增量应用并读取服务端快照 |
| 重复事件 | 按 `eventId`/气泡 ID 去重 |
| 气泡过期 | 禁止过期高影响操作，提供刷新 |
| 输入校验失败 | 在气泡输入区域显示具体错误 |
| 地点数据不可用 | 保留已加载结果并标注来源/时效 |
| 地图不可用 | 气泡仍可显示结构化结果和错误说明 |
| 未知气泡类型 | 降级为普通通知或错误，不执行未知动作 |

安全边界：

- 用户身份从 Supabase JWT 获取；
- 客户端不持有 `service_role`、LLM 密钥或高权限凭据；
- 气泡操作必须检查用户、会话、任务和资源归属；
- 不允许气泡文本直接触发任意 Flutter 操作；
- 不允许任意 URL、Storage 路径、文件路径或可执行动画脚本；
- 不在日志中记录令牌、敏感指令、内部提示词或其他用户数据；
- 行程和记忆高影响写入继续使用服务端权限、确认、幂等和 revision 校验。

## 14. 分阶段实施顺序

### 阶段 0：静态原型与布局验证

- 定义 `AgentOverlayState`、`AgentBubble` 和 `AgentVisualState` 的最小结构；
- 使用 Flutter 静态占位角色，不先绑定 Flame；
- 在地图 `Stack` 中实现小人、气泡和恢复入口；
- 验证 expanded/collapsed/hidden；
- 验证右上、左上锚点和障碍避让；
- 验证小人与气泡同时可见、键盘和文字缩放；
- 验证不影响地图拖拽、缩放、Marker 和地点详情。

阶段出口：布局和交互不变量在 Widget/Golden 测试中稳定，不依赖 Agent 后端。

### 阶段 1：结构化气泡渲染器

- 实现 `AgentBubblePanel`；
- 支持回答、地点列表、内容列表、单选、多选、输入问题、决策、进度和错误；
- 实现 payload 校验、动作白名单和过期处理；
- 补充 Semantics、焦点、键盘和内部滚动；
- 使用本地 Fixture 覆盖所有内容类型和失败状态。

阶段出口：气泡可以用结构化输入完成完整交互，不解析自由文本执行动作。

### 阶段 2：Agent 工作区最小垂直切片

- 实现 `SquadWorkspaceRepository`、快照读取和事件 Reducer；
- 将 `AgentCommandBar` 逐步接到结构化 `CaptainCommand`；
- 服务端至少创建 session、command 和 task；
- 将 `task.progressed`、`task.waiting`、`recommendation.proposed` 投影为气泡；
- 地点候选通过 `placeId` 驱动已有 Marker 和详情；
- 先采用轮询/快照，稳定后再接 Realtime。

阶段出口：任务、气泡、地点和地图投影来自同一工作区事实。

### 阶段 3：Flame 像素表现

- 在静态占位通过验证后引入 Flame；
- 建立本地资源白名单和 Sprite Sheet；
- 实现 `AgentVisualState → Flame animation` 映射；
- 实现暂停、恢复、隐藏和减少动态效果；
- 验证资源失败时 Flutter 回退；
- 验证 Android/iOS 平台视图合成和触摸行为。

阶段出口：Flame 只表现状态，业务状态不依赖 Flame 生命周期。

### 阶段 4：推荐、内容和行程联动

- 接入推荐 Artifact、地点列表和内容列表；
- 点击地点打开 `PlaceDetailSheet`；
- 接入来源、更新时间、置信度和风险；
- 接入 `DecisionCheckpoint`、行程草案和冲突；
- 用户确认后刷新地图和行程的同一 revision；
- 覆盖拒绝、撤销、过期和版本冲突。

### 阶段 5：真机、无障碍和性能验收

- Android 和 iOS 真机验证平台视图、手势、Z-order 和键盘；
- 验证小屏、横屏、文字缩放和减少动态效果；
- 测量地图 + Flame 叠加时的帧时长、CPU、GPU、内存和纹理；
- 验证 `IndexedStack` 切页后离屏动画暂停；
- 验证弱网、断线、资源失败和 Agent 超时；
- 决定是否有必要建设独立像素地图模式。

## 15. 推荐文件拆分

建议沿现有 `features` 结构新增，具体目录可随实现调整：

```text
apps/mobile/lib/features/agent/
├── domain/
│   ├── agent_persona.dart
│   ├── agent_bubble.dart
│   ├── agent_overlay_state.dart
│   └── agent_visual_state.dart
├── application/
│   ├── workspace_repository.dart
│   ├── workspace_reducer.dart
│   └── bubble_command_service.dart
└── presentation/
    ├── agent_map_overlay.dart
    ├── agent_bubble_panel.dart
    ├── bubble_content.dart
    ├── agent_overlay_layout.dart
    ├── agent_flame_view.dart
    └── agent_persona_registry.dart
```

职责边界：

| 模块 | 负责 | 不负责 |
|---|---|---|
| `agent_flame_view.dart` | Sprite、帧动画、暂停和资源生命周期 | 任务事实、气泡文本、网络请求 |
| `agent_bubble_panel.dart` | 文本、列表、选项、输入框、决策卡和语义 | 直接调用 Supabase、猜地点 ID |
| `agent_visual_state.dart` | 任务/角色到视觉状态的纯映射 | 修改任务、行程或记忆 |
| `bubble_command_service.dart` | 动作校验、幂等和命令提交 | 解析展示文案执行副作用 |
| `agent_overlay_layout.dart` | 安全区、锚点、避让和尺寸 | 修改业务状态 |
| `AmapSurface` | 高德地图和平台视图适配 | Agent 气泡和角色业务 |
| `ExplorePage` | 组合地图、覆盖层、详情和指令栏 | 直接承担 Agent 编排 |

## 16. 测试与验收

### 16.1 单元测试

覆盖：

- expanded/collapsed/hidden 状态转换；
- 锚点候选和障碍避让；
- 气泡 Schema 和未知类型降级；
- 单选、多选和输入校验；
- 气泡命令的幂等、过期和序号校验；
- 事件去重、乱序和序号缺口；
- 快照恢复；
- `AgentTask/AgentPersona → AgentVisualState` 映射；
- 地点和内容条目的来源、时效、置信度和风险字段。

### 16.2 Widget/Golden 测试

按当前仓库的 `apps/mobile/test/` feature 组织方式新增测试，至少覆盖：

- 默认显示小人；
- expanded 时小人与气泡同时可见；
- collapsed 只保留小人；
- hidden 显示恢复入口；
- 回答、地点列表、内容列表、单选、多选、输入问题和决策卡；
- 气泡提交按钮的启用、禁用、加载、错误和过期；
- 地点项点击后触发正确 `placeId` 回调；
- `PlaceDetailSheet` 打开时气泡避让或收起；
- 搜索 chip、`_MapNotice` 和底部指令栏不被遮挡；
- 文本缩放、键盘和减少动态效果；
- Flame 资源失败时的 Flutter 静态回退。

普通 Widget 测试不能证明高德平台视图真实渲染，应使用替代地图组件测试组合逻辑，并另行进行真机验证。

### 16.3 集成/人工验证

至少验证以下流程：

1. 进入探索页，真实地图和默认小人同时出现；
2. 展开回答气泡；
3. 展开地点列表并选择地点；
4. 打开地点详情，再恢复 Agent 气泡；
5. 提交单选和多选；
6. 输入并提交疑问；
7. 打开行程草案决策卡并拒绝/确认；
8. 收起和隐藏 Agent，再通过入口恢复；
9. 切换到行程页，返回探索页；
10. 模拟 Realtime 重复、断线和序号跳跃；
11. 验证地图、气泡、推荐和行程与最新服务端快照一致；
12. 验证资源失败、地图失败、Agent 超时和弱网降级。

### 16.4 验收标准

#### 基础展示与布局

- **AC-AG-001**：进入探索页后，高德真实地图仍是主要视觉区域。
- **AC-AG-002**：默认状态显示像素小人或明确的 Flutter 静态回退角色。
- **AC-AG-003**：expanded 状态下小人与气泡同时清楚可见。
- **AC-AG-004**：气泡不遮住小人，标题、正文和主要动作不被裁剪。
- **AC-AG-005**：小人和气泡不遮挡底部指令栏、地点详情主要按钮和高德版权/归属信息。
- **AC-AG-006**：320、375、768 等常见宽度、横屏、键盘和大字体状态下布局不溢出。

#### 收起、隐藏与恢复

- **AC-AG-007**：用户可以收起气泡并恢复当前气泡。
- **AC-AG-008**：用户可以完全隐藏小人与气泡。
- **AC-AG-009**：hidden 状态存在明确的“打开 Agent 助手”恢复入口。
- **AC-AG-010**：收起或隐藏不取消任务、不删除气泡、不改变服务端状态。
- **AC-AG-011**：待确认决策、未读结果和输入问题不会因收起或隐藏丢失。

#### 气泡类型与动作

- **AC-AG-012**：回答气泡支持结构化阶段摘要。
- **AC-AG-013**：地点列表使用 `placeId`，可联动 Marker 和 `PlaceDetailSheet`。
- **AC-AG-014**：内容列表展示来源、更新时间和内容类型。
- **AC-AG-015**：单选只能提交一个有效选项。
- **AC-AG-016**：多选遵守最少/最多选择数限制。
- **AC-AG-017**：输入问题支持必填、长度、类型和错误提示。
- **AC-AG-018**：加载、失败、过期、成功和重复提交均有明确反馈。
- **AC-AG-019**：未知气泡类型或未知动作安全降级，不执行未注册操作。

#### Agent、Flame 与业务边界

- **AC-AG-020**：Flame 动画只由结构化 `AgentVisualState` 驱动。
- **AC-AG-021**：动画结束不会改变任务、地点、行程或记忆状态。
- **AC-AG-022**：Flame 不直接访问 Supabase、Agent Repository、地点仓库或高德控制器。
- **AC-AG-023**：Flame 资源或初始化失败时，气泡、文本和核心操作仍可用。
- **AC-AG-024**：Agent 不能下发任意远程资源、文件路径或可执行动画脚本。

#### 地图与行程联动

- **AC-AG-025**：地图拖拽、双指缩放和 Marker 点击不被非交互 Flame 区域拦截。
- **AC-AG-026**：气泡地点与地图地点使用同一 `placeId`。
- **AC-AG-027**：路线/行程草案使用同一 `draftId`、`tripId` 和 `revision`。
- **AC-AG-028**：未确认的草案不会写入正式行程。
- **AC-AG-029**：用户锁定的地点、时间和顺序不会被 Agent 覆盖。
- **AC-AG-030**：路线失败、版本冲突和数据过期以文本说明，不由像素动画掩盖。

#### 生命周期、无障碍与性能

- **AC-AG-031**：切换到行程页后，Agent 任务继续执行。
- **AC-AG-032**：`IndexedStack` 保活下，离屏 Flame 动画暂停。
- **AC-AG-033**：App 进入后台时非必要动画暂停。
- **AC-AG-034**：减少动态效果后，状态仍由文本、图标和语义标签完整表达。
- **AC-AG-035**：角色、气泡、选项、输入框和错误均可通过 TalkBack/VoiceOver 访问。
- **AC-AG-036**：连续地图操作和气泡更新无明显持续掉帧或内存增长。

#### 事件一致性与安全

- **AC-AG-037**：重复事件不会重复弹出气泡或执行写入。
- **AC-AG-038**：发现事件序号缺口时读取服务端工作区快照。
- **AC-AG-039**：断线恢复后任务、气泡、推荐和地图投影一致。
- **AC-AG-040**：高影响行程/记忆写入仍需服务端权限、确认、幂等和 revision 校验。
- **AC-AG-041**：气泡不包含内部思维链、系统提示词、密钥或其他用户数据。
- **AC-AG-042**：不对高德底图进行全屏滤镜、截图重绘、未经授权的瓦片预处理或重新分发。

## 17. 待确认事项与非目标

| 编号 | 待确认事项 | 推荐默认值 |
|---|---|---|
| OQ-AG-001 | MVP 首屏显示一个角色还是多个角色 | 先显示一个当前主导角色，其他角色进入协作详情 |
| OQ-AG-002 | 气泡是否允许排队 | 一个当前气泡 + 有限未读队列 |
| OQ-AG-003 | hidden 偏好是否跨启动保存 | 先页面/会话级，验证后再纳入用户偏好 |
| OQ-AG-004 | 气泡最大高度 | 地图区域约 40%–50%，内容内部滚动 |
| OQ-AG-005 | Flame 最终资源风格 | 轻量像素角色，资源键白名单化 |
| OQ-AG-006 | 输入型决策点是否复用 `DecisionCheckpoint` | 复用，增加结构化 `input` Schema |
| OQ-AG-007 | 高德平台视图上透明 Flame 层的跨平台行为 | Android/iOS 真机验证后固化 |
| OQ-AG-008 | 气泡普通输入是否支持离线草稿 | 可本地保留草稿；高影响命令不允许离线提交 |

明确非目标：

- 对高德地图做全屏像素化；
- 小人沿真实地理坐标或路线移动；
- 以气泡自由文本替代结构化 Artifact；
- 传统聊天消息历史；
- 复杂 3D 数字人、实时语音视频；
- Agent 通过动画直接写入行程或长期记忆；
- 将像素装饰作为地图、营业、距离或路线事实。

## 18. 相关文档与实现边界

- [`docs/项目计划书.md`](../项目计划书.md)：产品目标、MVP 范围和真实地图/像素覆盖层方向；
- [`docs/architechture/Agent小队与Flutter前端交互对接设计.md`](../architechture/Agent小队与Flutter前端交互对接设计.md)：AgentPersona、SquadWorkspaceState、事件、Realtime、Artifact 和队长确认；
- [`docs/architechture/行程表数据模型.md`](../architechture/行程表数据模型.md)：行程持久化、RLS、锁定、revision 和幂等；
- [`docs/develop/1.前端基础结构开发.md`](../develop/1.前端基础结构开发.md)：当前三页入口、探索页地图和底部指令栏；
- [`docs/开发日志.md`](../开发日志.md)：当前代码进度、路线小地图和真机验证遗留问题；
- `apps/mobile/lib/features/explore/explore_page.dart`：地图区域 `Stack` 的实际扩展点；
- `apps/mobile/lib/features/explore/amap_surface.dart`：高德地图适配边界；
- `apps/mobile/lib/features/explore/agent_command_bar.dart`：当前队长指令输入入口。

本文不修改 `trips`、`trip_days` 或 `trip_items` 的核心数据模型；视觉状态、气泡内容和收起偏好不得写入行程事实字段。

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-08-26 | 初始版本：定义探索页悬浮像素 Agent 小人、结构化气泡、多形态交互、收起/隐藏、地图分层、状态契约、实现顺序和验收标准 |
