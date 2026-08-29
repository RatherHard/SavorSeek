**寻味多 Agent 协作工作室设计**

《寻味》美食旅行 App · Agent 小队分工、工具与编排设计

**1 设计目标**

用户像“队长”一样下达指令，Agent 小队分工完成美食探索、推荐和路线规划。核心原则：

地图负责呈现真实空间，Agent 负责理解需求，长期记忆负责让推荐越来越贴合用户。

每个 Agent 可观察、可解释、可中断、可重试。

工具调用和事实数据必须可溯源，LLM 只做理解、排序、解释和汇总，不凭空生成事实。

高权限操作（写记忆、改行程）必须由用户确认或可撤销。

**2 Agent 总览**

|     |     |     |     |
| --- | --- | --- | --- |
| **编号** | **Agent** | **类型** | **是否 MVP 必须** |
| 0   | Captain 总控 | 编排层 | 必须  |
| 1   | Intent 需求理解 | 理解层 | 必须  |
| 2   | Map 地图探索 | 检索层 | 必须  |
| 3   | Content 内容研究 | 检索层 | 可延后 |
| 4   | Memory 偏好记忆 | 记忆层 | 必须（先只读） |
| 5   | Fact 事实核验 | 质量层 | 必须（轻量版） |
| 6   | Recommend 推荐决策 | 决策层 | 必须  |
| 7   | Route 路线规划 | 规划层 | 必须  |
| 8   | Present 结果汇总 | 表现层 | 必须  |
| 9   | Feedback 反馈学习 | 记忆层 | 可延后 |

说明：在原 8 个 Agent 基础上，新增了 Captain 总控和 Feedback 反馈学习；Content 内容研究在 MVP 阶段建议并入 Map 地图探索，等授权内容源确定后再独立出来。

**3 各 Agent 分工与工具**

**0\. Captain 总控**

职责：接收用户指令，创建任务，调度 Agent，处理超时、失败和重试，汇总结果。

输入：用户原始指令、会话上下文、当前定位、App 页面状态。

输出：任务计划、Agent 调度事件、最终交付给前端的结果。

工具：所有 Agent 的工具都经 Captain 统一调用；Captain 本身不直接访问地图数据。

成功标准：任何用户指令都能在有限时间内给出可理解的结果或明确的失败原因。

**1\. Intent 需求理解 Agent**

职责：把自然语言指令解析成结构化约束。

输入：用户文本、当前时间、定位、会话历史。

输出：CaptainCommand，包含地点、时间、人数、预算、菜系、忌口、用餐类型、是否要路线等。

工具：parse_command（LLM 结构化抽取）、extract_constraints。

成功标准：硬性约束（如“不要辣”“每人 150 元”）不丢失；缺省项显式标注为未知。

**2\. Map 地图探索 Agent**

职责：根据约束召回候选餐厅和美食点。

输入：CaptainCommand 中的城市、区域、菜系、关键词。

输出：MapCandidates，每个候选包含 id、名称、类别、地址、坐标、来源、更新时间。

工具：search_places(keywords, city) 复用 places-search；search_around(lat, lng, radius) 周边检索；get_city_bounds(city) 城市定位；pixel_world_generate(city) 可选，生成城市像素地图供展示。

成功标准：候选覆盖约束区域，结果有坐标和来源，不做无依据的排序。

**3\. Content 内容研究 Agent**

职责：整理授权内容源中的探店信息、特色描述和用户经验。

输入：候选地点 id、内容来源白名单。

输出：ContentBrief，包含特色菜品、推荐理由、用户评价摘要、来源链接、抓取时间。

工具：search_content(query)、summarize_source(url)、deduplicate_content(items)。

成功标准：所有内容可溯源；非授权来源不进入结果。

**4\. Memory 偏好记忆 Agent**

职责：读取用户长期偏好，并在用户同意时更新偏好。

输入：用户 id、会话上下文。

输出：UserMemory，包含口味、预算、忌口、去过/收藏过的地点、当前会话临时偏好。

工具：read_memories(user_id)、write_memory(user_id, item)、delete_memory(user_id, id)。

成功标准：只读模式下不改写记忆；写入必须带用户确认或显式反馈。

**5\. Fact 事实核验 Agent**

职责：检查营业时间、地址、重复信息和明显冲突，标记不确定内容。

输入：候选地点、内容摘要、历史数据。

输出：VerifiedPlaces，每个地点带 verified、confidence、warnings。

工具：verify_place(place_id)、check_hours(place_id)、deduplicate_places(candidates)、flag_conflicts(items)。

成功标准：不把“营业时间可能已变”说成确定事实；冲突项必须有提示。

**6\. Recommend 推荐决策 Agent**

职责：综合需求、偏好、地点特征和信息可信度进行排序。

输入：CaptainCommand、UserMemory、VerifiedPlaces。

输出：RecommendationList，含排序分数、匹配理由、不确定提示。

工具：rank_places(candidates, constraints, memory)、explain_recommendation(place)。

成功标准：硬约束优先，软偏好次之；每个推荐都能解释为什么。

**7\. Route 路线规划 Agent**

职责：结合营业时间、距离、停留时长和交通方式生成可执行路线。

输入：推荐地点、起点、日期、餐段、交通方式、停留时长。

输出：RoutePlan，含顺序、到店时间、停留时间、交通方式、总时长。

工具：plan_route(places, mode) 复用 trip-route；check_open_hours(place, time)；build_trip_draft(plan)。

成功标准：时间冲突被检查；路线调整后自动重新计算后续时间。

**8\. Present 结果汇总 Agent**

职责：把推荐、路线和来源整理成用户能直接操作的界面结果。

输入：RecommendationList、RoutePlan、VerifiedPlaces。

输出：Presentation，含卡片列表、地图标记、理由、来源、可执行按钮（加入行程、收藏、去像素地图）。

工具：create_trip_draft、add_trip_item、publish_event、format_source。

成功标准：用户无需再读原始文本就能判断“为什么推荐这家、要不要加入行程”。

**9\. Feedback 反馈学习 Agent**

职责：处理用户反馈（喜欢、不喜欢、不准确），更新偏好和质量信号。

输入：用户反馈、推荐结果、用户操作。

输出：FeedbackRecord 和可选的 UserMemory 更新建议。

工具：record_feedback、suggest_memory_update、report_quality_issue。

成功标准：反馈可撤销；不因一次反馈就永久改写用户画像。

**4 工具清单**

|     |     |     |     |     |
| --- | --- | --- | --- | --- |
| **工具** | **归属 Agent** | **后端实现** | **来源** | **可参考开源项目** |
| parse_command | Intent | LLM + 结构校验 | 新增设计，需开发 | [instructor-js（结构化抽取）、langchainjs](https://github.com/567-labs/instructor-js) |
| search_places | Map | 现有 places-search | 仓库已有 | 无需  |
| search_around | Map | 现有 places-search | 仓库已有 | 无需  |
| get_city_bounds | Map | 新增 pixel-world 接口（高德行政区 + 缓存） | 新增设计，需开发 | [Administrative-divisions-of-China（省市区边界数据）](https://github.com/modood/Administrative-divisions-of-China) |
| pixel_world_generate | Map / Present | 新增 pixel-world 接口 | 新增设计，需开发 | [OpenPixel-RPG、Isometric NYC（生成思路）](https://github.com/tensor2023/OpenPixel-RPG) |
| search_content | Content | 待接入授权源 | 新增设计，需接入第三方 / 授权源 | 无需（取决于授权内容源） |
| read_memories | Memory | 新增 memory 函数 | 新增设计，需开发 | [mem0（AI 记忆层）](https://github.com/mem0ai/mem0) |
| write_memory | Memory / Feedback | 新增 memory 函数 | 新增设计，需开发 | [mem0](https://github.com/mem0ai/mem0) |
| verify_place | Fact | 高德详情 + 缓存 | 新增设计，需开发 | [splink、dedupe（实体匹配思路）](https://github.com/moj-analytical-services/splink) |
| deduplicate_places | Fact | 服务端纯函数 | 新增设计，需开发 | [splink、dedupe](https://github.com/dedupeio/dedupe) |
| rank_places | Recommend | LLM 排序 + 规则校验 | 新增设计，需开发 | [recommenders（推荐排序思路）](https://github.com/recommenders-team/recommenders) |
| plan_route | Route | 现有 trip-route | 仓库已有 | 无需  |
| create_trip_draft | Route / Present | 现有行程 RPC | 仓库已有 | 无需  |
| add_trip_item | Present | 现有行程 RPC | 仓库已有 | 无需  |
| publish_event | Captain / Present | Supabase Realtime | 平台能力，需配置 | 无需  |

来源说明：仓库已有表示这些函数或接口已经在我们 GitHub 仓库里实现；新增设计表示目前还没有对应文件，只是建议要开发的接口；待接入表示需要外部平台授权后才能做。

**4.1 开源项目怎么用**

**可直接参考（与后端同为 TypeScript 生态）**

**langchainjs：**[TypeScript 版 LangChain，官方支持 Agent 和工具调用编排。我们后端是 Supabase Edge Functions（TypeScript），这是最接近“直接能用”的编排框架。](https://github.com/langchain-ai/langchainjs)

**instructor-js：**[TypeScript 结构化输出库，把 LLM 回答稳定解析成 JSON，对应 parse_command。](https://github.com/567-labs/instructor-js)

**openai-agents-python：**[OpenAI 官方 Agent SDK，已有 Python 和 TypeScript 两个版本，适合做 Captain 的 Agent 循环和工具调用。](https://github.com/openai/openai-agents-python)

**Administrative-divisions-of-China：**[中国五级行政区划数据（省、市、区、街道、村），JSON / CSV 格式，可缓存到 Supabase，替 get_city_bounds 提供城市和区县边界数据。](https://github.com/modood/Administrative-divisions-of-China)

**phoenix：**[LLM 可观测性与评测平台，记录每次 Agent 调用、追踪反馈、发现哪一步质量差，对应 record_feedback 和整体排障。](https://github.com/Arize-ai/phoenix)

**只能借鉴思路（Python 为主，不能直接进 Edge Functions）**

**mem0：**[AI 记忆层，有 Python 和 JavaScript 版本，但完整能力以 Python 为主；可借鉴“分层记忆 + 检索”的设计，在自己后端用 Postgres 实现，或单独部署记忆服务。](https://github.com/mem0ai/mem0)

**crewAI：**[多 Agent 编排框架，核心是 Python；TypeScript 只有社区移植版且不成熟。可借鉴它的 Crew / Task / Tool 结构，但别直接依赖。](https://github.com/crewAIInc/crewAI)

**recommenders：**[微软开源推荐系统框架，纯 Python，主要给离线训练和评测用。MVP 阶段建议只参考它的“规则 + 分数排序”思路。](https://github.com/recommenders-team/recommenders)

**splink 和 dedupe：**[数据去重 / 实体匹配库，都是 Python。可借鉴“字段相似度打分、人工确认阈值”的方法，自己写轻量版 TypeScript 去重函数。](https://github.com/moj-analytical-services/splink)

**技术方案落地原则**

后端已确定是 Supabase Edge Functions（TypeScript + Deno），优先选 TypeScript / JS 生态的开源项目。

Python 项目要么参考思路自己实现，要么单独开一个 Python 服务通过接口调用，不要硬塞进 Edge Functions。

开源项目只解决通用编排、解析、记忆、去重等通用问题；地图、行程、推荐理由等业务逻辑仍要自己写。

引用前检查许可证：MIT / Apache-2.0 通常可商用；GPL 类要谨慎

**5 编排流程**

用户指令

└─ Captain 创建 session + command

├─ Phase A（并行）：Intent 解析需求 + Memory 读取偏好

├─ Phase B（并行）：Map 召回候选 + Content 整理内容（MVP 可跳过）

├─ Phase C：Fact 核验候选

├─ Phase D：Recommend 排序

├─ Phase E（可选）：Route 生成路线

├─ Phase F：Present 汇总并落库

└─ 异步：Feedback 学习

编排规则：

串行依赖：Map 依赖 Intent，Recommend 依赖 Fact，Present 依赖 Recommend / Route。

并行分支：Intent 与 Memory 并行；Map 与 Content 并行。

超时：Intent 5s，Map 15s，Content 20s，Fact 10s，Recommend 8s，Route 15s，Present 5s。

失败：单 Agent 失败默认重试一次；重试仍失败则降级（如没有 Content 仍可推荐，没有 Route 仍可展示列表）。

用户中断：任何阶段都可取消，已写入的行程草稿保留为可撤销状态。

**6 数据契约示例**

{

"session_id": "sess_01",

"command": "明天下午在成都宽窄巷子附近，两个人，人均150，不吃辣，帮我安排一顿晚餐路线",

"parsed": {

"city": "成都",

"area": "宽窄巷子",

"time": "2026-08-29T18:00",

"party_size": 2,

"budget_per_person": 150,

"avoid": \["辣"\],

"meal_type": "dinner",

"need_route": true

},

"candidates": \[

{

"place_id": "p_01",

"name": "示例川菜馆",

"category": "中餐",

"address": "宽窄巷子",

"verified": true,

"confidence": 0.92,

"warnings": \["营业时间来自缓存"\]

}

\],

"route": {

"order": \["p_01"\],

"start": "18:00",

"mode": "walking"

}

}

**7 与现有仓库的关系**

agent Edge Function 现在是占位实现，未来作为 Captain 入口。

places-search 直接成为 search_places / search_around 工具。

trip-route 直接成为 plan_route 工具。

pixel-world 是规划中的新增接口，用于城市定位和像素地图生成，当前尚未实现，需开发。

新增 memory 和 agent-tools 类 Edge Function 负责偏好记忆与反馈。

数据库新增 squad_sessions、captain_commands、agent_tasks、agent_events，用于观察任务状态。

Flutter 端 AgentCommandBar 提交指令，通过 Supabase Realtime 接收事件流，展示 Agent 小队工作状态。

**8 MVP 裁剪建议**

MVP 保留：Captain、Intent、Map、Memory（只读）、Fact（轻量）、Recommend、Route、Present。

MVP 延后：Content 内容研究、Feedback 写入长期偏好、深度事实核验。

理由：先把“用户说需求 → 地图给候选 → 推荐理由 → 路线 → 加入行程”这条主线跑通，再叠加内容与长期记忆，避免一周内堆出无法验证的复杂编排。

**9 风险与降级**

LLM 幻觉：所有事实都来自工具结果，LLM 只做结构化抽取、排序和解释；关键字段做枚举校验。

高德配额：服务端缓存 + 单次任务限流 + 配额错误明确提示。

数据过期：所有地点和内容保留 fetched_at，界面展示更新时间。

长任务：用事件流而不是同步等待，前端展示“正在搜索 / 正在核验 / 正在规划”阶段。

用户信任：推荐必须给理由和来源；写记忆、改行程必须可撤销。