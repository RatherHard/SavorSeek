# Plan: 探索页地图美食地点标记筛选与稀疏显示

> 供后续 implementation agent 执行。本文件只描述实现方案、边界与验收标准；本轮不修改生产代码、数据库迁移或其他文档。
>
> 生成日期：2026-08-28  
> 当前分支：`dev`  
> 重要基线：工作区已有探索地图、视野检索、地点检索控制器及相关测试的未提交改动。实施 agent 必须先读取并保留这些改动，不得用旧版本覆盖；也不得把本计划误当成已经完成的实现。

## 1. 需求重述

为探索页的地图标记增加一个**内部、用户不可见**的地点选择系统：

1. 地图标记只保留美食相关地点，排除明显的非餐饮 POI。
2. **评分直接采用高德 POI 接口返回的 `rating`**；只有存在合法评分的美食地点才进入自动 marker 候选，没有评分或评分异常的地点一律不纳入地图标记筛选。
3. 在合格的美食地点中优先展示评分高的地点；评分相同使用确定性的稳定排序。
4. 根据当前地图相机的缩放级别、地图在屏幕上的实际可用宽高以及瓦片地图的米/像素尺度，动态决定：
   - 向服务端请求的周边范围；
   - 候选地点数量（必要时翻页）；
   - 最终可渲染的标记数量。
5. 通过空间稀疏算法避免标记在屏幕上重叠或视觉拥挤，同时保留高评分地点优先级。
6. 保留现有地点详情、Marker 点击映射、关键词结果抽屉、收藏和加入行程行为；评分筛选只影响地图标记层，不能悄悄破坏用户检索结果列表。

## 2. 当前代码基线与必须镜像的模式

### 2.1 现有数据流

```text
ExplorePage
  ├─ CameraPosition.onCameraMoveEnd
  ├─ buildMapViewportQuery(...)          # 依据 zoom + 屏幕尺寸估算半径
  ├─ PlaceSearchController.searchAround
  ├─ PlaceRepository.searchAround
  ├─ Supabase Edge Function places-search (kind=around)
  └─ _resolveMarkers() -> AmapSurface -> AMapWidget
```

| 类别 | 来源 | 需要遵守的模式 |
|---|---|---|
| 地图职责边界 | `apps/mobile/lib/features/explore/amap_surface.dart:8-12` | 地图组件只负责底图、覆盖物和事件转发；筛选、聚合、排序留在上层或纯 Dart 服务，不把业务塞进 `AmapSurface`。 |
| 相机视野计算 | `apps/mobile/lib/features/explore/map_viewport.dart:25-71` | 使用 `metersPerPixel`、实际尺寸和保守半径；输入非法返回 `null`；查询 key 归一化以减少缓存穿透。 |
| 相机事件与防抖 | `apps/mobile/lib/features/explore/explore_page.dart:106-135` | 相机停止后 400ms 防抖；请求显式经 `PlaceSearchController`，使用 `unawaited` 表达有意的异步触发。 |
| 标记构造与点击映射 | `apps/mobile/lib/features/explore/explore_page.dart:75-84,385-427` | Marker id 在构造时生成，必须同步维护 `marker.id -> Place`；缓存同一批标记，避免每帧全量重建造成闪烁。 |
| 搜索状态与竞态 | `apps/mobile/lib/features/places/place_search_controller.dart:101-218` | 使用 request id 丢弃过期响应；失败时保留上一批结果；关键词结果不能被视野刷新静默替换。 |
| 地点模型 | `apps/mobile/lib/features/places/place_models.dart:7-80` | `Place` 不依赖地图 SDK，保持不可变、空安全；供应商类别串按 `;` 分层并通过 `primaryCategory` 展示。 |
| 数据访问 | `apps/mobile/lib/features/places/place_repository.dart:50-64,99-141` | 复用既有 repository 与 Edge Function，不由客户端直调高德 Web API；参数必须保持类型明确。 |
| 服务端 around 契约 | `supabase/functions/places-search/index.ts:147-177` | 当前支持 `latitude/longitude/radius/keywords/page`，半径上限 50,000m、页码 1-10；增加参数时需同步校验、缓存 key 和客户端。 |
| 高德请求与字段最小化 | `supabase/functions/places-search/amap.ts:15-16,110-137,209-265` | 当前 `extensions=base`，只保留最小字段；如评分需要 `extensions=all` 或其他字段，必须先核对高德接口/授权和缓存合规性，再只归一化必需字段，禁止把完整响应下发或长期保存。 |
| 测试风格 | `apps/mobile/test/explore/map_viewport_test.dart:3-71`、`apps/mobile/test/places/place_search_controller_test.dart:7-55` | 使用 `flutter_test`、手写 fake、行为导向测试；纯算法优先单元测试，异步竞态使用 `Completer`；新逻辑按 RED-GREEN-REFACTOR 执行。 |

### 2.2 已确认的缺口

- `Place` 当前没有评分或评分人数；`category` 是供应商原始类别串。
- 当前 `buildMapViewportQuery` 已按宽高估算半径，但 `ExplorePage` 在 `:121-123` 固定传 `360 x 640`，不是地图实际布局尺寸。
- 当前 `searchAround` 客户端接口没有暴露 `page`，服务端虽然支持 1-10 页，但一次 around 请求实际只取一页 `PAGE_SIZE=20`。
- 当前 marker 使用 `search.visiblePlaces`，没有美食分类过滤、评分排序或空间去拥挤。
- 当前地图插件没有被代码证明能稳定提供精确 visible region；实现应继续采用保守估算，不能声称拿到了精确矩形。

## 3. 范围与非目标

### 本轮范围

- 新增可独立测试的纯 Dart 标记选择策略。
- 将实际地图尺寸传入视野查询和标记选择，而不是继续使用固定尺寸。
- 增加美食类别判定、**高德 `rating` 强制评分过滤/降序排序**、空间网格/最小间距稀疏和动态数量上限。
- **必须直接接入高德 POI 接口的 `rating` 字段**，并同步服务端最小字段归一化、公共缓存、数据库、客户端模型和测试；没有合法评分的地点不得进入自动 marker 候选。
- 更新探索页仅对 marker 层应用选择结果；结果抽屉仍使用原始 `visiblePlaces`，但没有评分的地点不得进入自动 marker 集合。

### 明确不做

- 不新增用户可见筛选按钮、筛选面板、开关、提示文案或设置项。
- 不在客户端直连高德 Web API，不下发高德 Web Service Key。
- 不把非美食地点从服务端公共 `places` 表删除；过滤是地图展示策略，不是数据清洗。
- 不凭地点名称、类别之外的猜测给出评分；评分必须来自高德接口的 `rating` 字段。
- 没有评分、评分为空、无法解析、非有限值或超出 0～5 范围的地点，一律不进入自动地图 marker 候选；这类地点仍可保留在关键词结果抽屉中。
- 不使用评分缺失降级展示策略，也不把缺失评分当作 0 分。
- 不修改 `AmapSurface` 的通用业务职责，不影响行程页的小地图和路线图调用方。
- 不改写工作区中与本需求无关的未提交代码或文档；除非用户另行授权，不修改 `docs/`。
- 不把实时聚合、服务端空间索引、PostGIS 或复杂聚类框架引入 MVP；先使用当前候选集上的确定性纯 Dart 算法。

## 4. 目标行为与算法契约

### 4.1 地图尺寸与视野查询

1. 在探索页地图实际布局处使用 `LayoutBuilder` 或等价的约束来源，取得有限且大于 0 的地图逻辑像素宽高。不得继续把 `360 x 640` 作为生产调用的固定值。
2. 相机停止事件要携带（或可读取）当前尺寸，使 `buildMapViewportQuery` 用真实 `width/height + zoom + latitude` 计算保守半径。
3. 延续现有校验：非法经纬度、zoom、宽高返回 `null`；半径仍受服务端 50km 上限约束；归一化 key 必须包含会影响查询的尺寸/策略参数，避免同一相机在不同屏幕尺寸下错误复用缓存。
4. 保留现有 400ms 防抖、相同 query key 不重复请求和 request-id 防乱序行为。
5. 如果地图插件/瓦片尺寸无法通过稳定 API 取得，明确将默认瓦片尺寸（通常为 256 logical px）作为内部计算常量或策略参数，并在注释中说明这是米/像素估算，不是精确可见矩形；不要伪造插件能力。

### 4.2 美食类别过滤

新增纯函数/策略（建议新文件 `apps/mobile/lib/features/explore/map_marker_selection.dart`，命名以现有目录习惯为准）：

- 输入：不可变 `List<Place>` 和选择上下文。
- 输出：不可变、去重、稳定排序后的地点列表。
- 只把供应商类别明确落在餐饮/美食类别的地点作为自动 marker 候选，例如餐饮服务、餐厅、中餐、西餐、快餐、烧烤、火锅、咖啡、茶饮、甜品、小吃、地方菜等；具体 allowlist/denylist 必须从高德类别编码/当前 fixtures 归纳，并集中定义，不要散落字符串判断。
- 明显非美食类别（景点、购物、交通、住宿、医院、学校、政府、汽车服务等）排除。
- 类别为空或无法判断时，默认排除自动 marker，避免地图出现非美食地点；同时保留该地点在搜索结果列表中。
- 类别比较需 trim、大小写/全半角和 `;` 分层兼容；不能只依赖展示用 `primaryCategory` 的最后一级而误排合法父级类别。
- 同一地点 id 只保留一次；无坐标地点不进入 marker 候选。
- 关键词检索与自动视野检索都经过 marker 过滤，但不改变 `PlaceSearchController.visiblePlaces`，确保抽屉仍可展示服务端原始结果。

### 4.3 高德评分强制过滤与排序

本轮不再提供“评分暂不可用”或“评分缺失降级展示”方案。自动地图 marker 的候选资格必须同时满足：

1. 类别属于美食/餐饮；
2. 有有效坐标；
3. **高德 POI 接口直接返回合法 `rating`**。

评分只能来自高德接口响应，禁止根据名称、类别、用户本地数据或其他推断生成评分。没有评分、评分为空、字段类型错误、无法解析、非有限值或超出 0～5 范围的地点，一律在 marker 筛选阶段排除，不参与排序、网格占位、数量统计或翻页补足。它们是否继续出现在关键词结果抽屉中保持现有 `visiblePlaces` 语义，不代表它们进入地图 marker 候选。

实施时必须：

- 在高德服务端 POI 请求中启用能够返回 `rating` 的官方响应扩展（以当前接口文档和真实餐饮 POI 响应为准；若 `base` 不返回则使用接口要求的扩展级别，通常需验证 `all`），并为评分字段写真实响应 fixture/解析测试。
- 在 `NormalizedPlace`、Edge Function 响应、`Place` 模型和公共 `places` 缓存中使用 typed nullable `rating` 字段。字段允许 nullable 只是为了表达上游缺失和保持数据边界安全，**不是允许 marker 使用无评分地点**。
- 只保留必要的评分标量，不把完整 `biz_ext` 或高德原始响应暴露给客户端；评分来源仍应记录为高德接口字段，不从 `raw` 的任意 JSON 路径临时读取。
- 若高德接口的评分字段需要 `extensions=all`，缓存查询参数必须包含扩展级别和契约版本，防止旧 `base` 缓存被误认为已带评分；已存在的无评分缓存不得被当作合格候选，必要时按新版本 key 重新回源。
- 若高德接口在真实餐饮 POI 上仍不返回 `rating`，则实现必须报告为阻塞并不得宣称需求完成；不得用替代评分、默认值或缺失降级绕过本要求。

排序规则必须确定且可测试：

1. 先过滤美食、有效坐标和合法高德评分；
2. 合格地点按 `rating` 降序；评分相同再按稳定字段（距离地图中心、地点 id）排序；
3. 所有评分需做有限值和 0～5 范围校验；异常值直接排除，而不是视为 0 分；
4. 最终 tie-break 必须稳定，保证相同输入不会因服务端返回顺序或 `Set` 迭代顺序导致 marker 抖动。

### 4.4 动态候选数量与空间稀疏

选择策略必须是确定性的纯 Dart 逻辑，至少包含以下输入：

- 地图中心纬度/经度；
- zoom；
- 实际地图逻辑像素宽高；
- 当前视野查询半径/米每像素；
- 候选地点（含坐标、类别、评分）；
- 内部常量配置（marker footprint、cell size、最小/最大 marker 数、候选页数上限）。

建议算法：

1. 用当前纬度和 zoom 的 Web Mercator 近似将候选经纬度投影为相对屏幕像素，或使用局部等距近似；经度跨 ±180°、高纬度和非法坐标要有明确处理。
2. 将地图划分为以 marker 可视占用尺寸为基础的网格（例如 footprint 加间距），只在**已通过美食类别、有效坐标和高德合法评分过滤**的候选中，按“评分降序、中心距离/稳定 id”顺序贪心选择：同一网格只保留最佳地点，邻接网格也可按配置合并，保证图标不会明显重叠。
3. 动态目标数量应由屏幕面积和 cell 面积计算，并 clamp 在明确的 `minMarkers`/`maxMarkers` 内；低 zoom/超大半径时更严格限流，高 zoom/小范围时允许更多可辨识地点，但绝不能超过候选数。
4. 标记选择应优先覆盖多个空间网格，而不是简单取评分 Top-N；当高评分地点集中在同一区域时，仍为其他可见区域保留代表点。
5. 对保守半径内但明显在屏幕外的候选，若无法取得精确矩形，允许进入候选但必须经投影/边界估算和网格选择；在注释中写清近似性质。
6. 返回 `List.unmodifiable` 或等效不可变结果，并提供可用于 marker 缓存的稳定 selection key（包含候选批次 identity/query key、相机归一化参数和策略版本）。
7. 不在 build 方法内做网络请求或高复杂度循环；选择逻辑在搜索结果变化/相机停止时计算，`_resolveMarkers` 只消费已缓存的选择结果并构造 Marker。

### 4.5 服务端候选页数

优先复用现有 around 接口和缓存。若动态目标数量可能超过现有 `PAGE_SIZE=20`：

- 扩展 `PlaceRepository.searchAround`、controller 和 Edge Function 调用以支持受校验的 `page`，或设计一个受控的内部候选数量参数；不要让客户端任意扩大高德请求。
- 只在较宽视野且确实需要时请求有限的后续页（建议最多 2 页，受 MAX_PAGE/配额约束），顺序合并并按地点 id 去重；页请求应可取消/被新 request id 作废。
- 每个页面参数必须进入缓存 key；错误时保持已有结果，不能因为第二页失败抹掉第一页。
- 若当前数据量和产品目标不需要翻页，则明确将 20 条作为候选上限，在验收中验证“最终 marker 数不超过候选数”，不要为了理论容量无条件增加网络请求。

## 5. 文件与接口变更清单

| 文件 | 动作 | 目的 |
|---|---|---|
| `apps/mobile/lib/features/explore/map_marker_selection.dart` | CREATE（推荐） | 纯 Dart 的美食过滤、评分排序、空间投影、网格稀疏和动态 marker 上限；不依赖 Flutter/高德 SDK。 |
| `apps/mobile/test/explore/map_marker_selection_test.dart` | CREATE | 覆盖过滤、评分、坐标、空间冲突、数量上限和稳定性。 |
| `apps/mobile/lib/features/explore/map_viewport.dart` | UPDATE | 在现有视野估算基础上接收实际尺寸；必要时把影响缓存的尺寸/候选策略纳入 key；保留现有非法输入和半径上限行为。 |
| `apps/mobile/test/explore/map_viewport_test.dart` | UPDATE | 增加宽高变化影响半径/key、窄屏/大屏和边界 zoom 的回归测试；保留当前测试。 |
| `apps/mobile/lib/features/explore/explore_page.dart` | UPDATE | 从实际 LayoutBuilder 取得地图尺寸；维护当前相机/选择上下文；将 `visiblePlaces` 转为 marker selection；保持 marker id 映射缓存、搜索抽屉和详情交互。 |
| `apps/mobile/lib/features/explore/amap_surface.dart` | UPDATE（仅必要时） | 只在需要转发尺寸/相机信息且无法由上层 LayoutBuilder 完成时修改；不得把筛选业务放入组件。优先不改该文件。 |
| `apps/mobile/lib/features/places/place_models.dart` | UPDATE（必须） | 增加来自高德的 nullable、范围受校验的 `rating` 字段，并保持不可变和无地图 SDK 依赖；marker 选择只接受合法评分。 |
| `apps/mobile/lib/features/places/place_repository.dart` | UPDATE（按翻页/评分契约需要） | 同步 typed 评分字段和受控分页参数与现有服务端 around 接口；维持鉴权、异常分类和 repository 边界。 |
| `apps/mobile/lib/features/places/place_search_controller.dart` | UPDATE（按翻页需要） | 合并/去重候选页，保留 request-id、上一批结果和关键词优先规则；不把 marker 过滤结果冒充搜索结果。 |
| `apps/mobile/test/places/place_search_controller_test.dart` | UPDATE（必须；分页部分按需） | 覆盖高德评分字段贯通、无评分保留在原始结果但不能进入 marker；若扩展分页，再覆盖 around 多页、乱序、旧结果保留和去重。 |
| `supabase/functions/places-search/amap.ts` | UPDATE（必须） | 启用并解析高德 `rating`，只归一化必要评分标量；候选分页按动态数量需要扩展。 |
| `supabase/functions/places-search/index.ts` | UPDATE（必须） | 将评分响应扩展/契约版本纳入固定缓存参数；分页参数继续严格校验。 |
| `supabase/migrations/<new_timestamp>_places_rating.sql` | CREATE（必须，若评分需持久化） | 通过前向迁移增加 nullable `rating` 字段及 0～5 约束，并同步 RPC 读写；先核对线上状态，不改历史迁移。 |
| `supabase/migrations/<existing>_places_rpcs.sql` | 不修改历史文件 | 仅作为现状参考；所有上线数据库变化放新迁移。 |

> 实施 agent 必须把高德 `rating` 接入作为本轮硬性前置条件：先用真实餐饮 POI 响应确认字段和所需 `extensions`，再同步服务端、缓存、数据库和客户端。若接口/权限/授权导致真实响应无法稳定取得评分，必须报告阻塞并停止本功能交付；不得用替代字段、默认值或缺失降级伪装完成。

## 6. 分阶段执行任务

### Task 0：基线核对与契约决策

- **Action**：读取上述文件及当前工作区 diff；核对高德官方 Web API POI 响应中的 `rating` 字段、`extensions` 配置、真实餐饮 POI fixture、服务条款和现有缓存策略；核对线上迁移状态（如实施环境允许）与当前 Edge Function 契约。评分接入是硬性前置条件，不得跳过。
- **Mirror**：遵循 `place_repository.dart` 的服务端代理边界与 `amap.ts` 的最小字段原则。
- **Validate**：必须拿到真实或官方格式的餐饮 POI 响应，证明 `rating` 可被稳定解析；确定使用的 `extensions`、字段映射、0～5 校验、缓存契约版本和数据库迁移方案。若证明失败，报告阻塞并停止本功能交付。

### Task 1：先写纯逻辑失败测试（RED）

- **Action**：创建 `map_marker_selection_test.dart`，先写失败测试：
  - 餐饮类别保留，景点/住宿/购物/空类别排除；分层类别与脏空白可识别；
  - 无坐标排除、重复 id 去重；
  - 评分必须来自高德 `rating`：5 分高于 4 分；无评分、无法解析、非有限值、超出 0～5 范围的地点全部被排除，不得进入结果；
  - 没有评分的地点即使是美食、有坐标，也不得进入 marker；但原始关键词结果列表仍按既有语义保留；
  - 大小不同的地图得到不同目标数量；最终数量不超过候选数及 max；
  - 相同输入返回相同 id 顺序；候选输入顺序变化不改变结果（在 tie-break 可定义的前提下）；
  - 边界纬度、跨经度、无效尺寸/zoom 不崩溃。
- **Validate**：`flutter test test/explore/map_marker_selection_test.dart` 在实现前应按预期失败（或因文件不存在失败），不得以删除断言方式“通过”。

### Task 2：实现纯 Dart 选择策略（GREEN/REFACTOR）

- **Action**：实现 typed 配置、**高德评分强制过滤**、美食类别过滤、评分降序、投影/网格稀疏和不可变输出；将魔法数字集中为内部常量，并对输入做有限性/范围校验。
- **Mirror**：使用 Dart 3 sealed/pattern 和 `final`/不可变集合；不引入 Flutter 或地图 SDK；没有合法评分的候选安全排除，不做默认评分或替代字段回退。
- **Validate**：运行单测、`dart format`，确认评分缺失地点无法通过任何路径进入 marker，检查算法复杂度对候选上限可控。

### Task 3：让视野计算使用真实地图尺寸

- **Action**：用 `LayoutBuilder`/约束把地图可用宽高传给视野查询和 marker selection；删除生产路径中固定 `360 x 640` 的依赖；更新 query key 和测试。
- **Mirror**：保留 `map_viewport.dart` 的保守圆形估算，不声称精确矩形；保留 400ms debounce 和相同 key 去重。
- **Validate**：`flutter test test/explore/map_viewport_test.dart`；用窄屏、大屏、zoom 变化验证半径单调性和 key 不错误复用。

### Task 4：接入探索页 marker 层

- **Action**：在 `_ExplorePageState` 中维护当前相机/尺寸与 selection 结果；搜索结果变化或相机停止时重新选择；`_resolveMarkers()` 只构造选中的地点并维护 id 映射。继续让 `PlaceResultsDrawer` 接收原始 `search.visiblePlaces`。
- **Mirror**：遵循 `explore_page.dart:385-427` 的 Marker 缓存和点击映射；不得每次 build 新建同一批 Marker；未坐标地点继续跳过。
- **Validate**：扩展 `explore_page_test.dart` 或新增纯 widget 回归测试，证明 marker 层过滤不影响列表、选中/清除详情、收藏和加入行程；验证无 repository、未登录、未同意地图时不触发新请求。

### Task 5：强制接入高德评分契约，并按需要扩展候选分页

- **Action**：必须同步高德 POI 请求、Edge Function 类型与解析、最小 `rating` 归一化、数据库前向迁移/RPC、客户端 `Place.rating` 和缓存契约版本；没有合法评分的地点必须在 marker 选择前排除。分页仍仅在动态目标数量确有需要时扩展。
- **Mirror**：遵循 `places-search/index.ts` 的输入校验、错误分类和 `amap.ts` 的 timeout/最小字段；数据库只通过 security definer RPC 写入，不能开放公共表写权限。
- **Validate**：使用真实/官方格式响应 fixture 覆盖高德 `rating` 解析、空值/数组/非法值处理、旧缓存隔离和数据库 0～5 约束；客户端测试覆盖评分字段解析及无评分 marker 排除。若扩展分页，再覆盖多页合并、去重、乱序和部分失败保留旧结果。

### Task 6：整体验证与代码审查

- **Action**：执行格式、分析、全部 Flutter 测试；检查所有未提交 diff，确认未误改现有任务文件；使用 code-reviewer 和 security-reviewer 审查新增网络/数据字段与 marker 逻辑。
- **Validate**：见第 8 节；发现构建错误时使用 Dart/Flutter build resolver 做最小修复，不借机重构无关模块。

## 7. 风险与缓解

| 风险 | 可能性 | 缓解 |
|---|---:|---|
| 当前地点模型/缓存没有评分字段，评分链路必须完整接入 | 高 | 使用高德 POI `rating` 作为唯一评分来源；同步请求扩展、typed 解析、缓存契约版本、前向迁移、RPC 和客户端模型，禁止默认评分或降级替代。 |
| `extensions=all` 可能增大响应与缓存合规风险 | 中 | 仅抽取并持久化 `rating` 必需标量，不保存/下发完整扩展响应；更新缓存契约版本并验证接口授权。 |
| 高德对部分餐饮 POI 不返回评分，候选数量减少 | 高 | 按需求直接排除无评分地点；必要时仅通过受控翻页扩大候选池，不降低评分门槛、不回退到无评分地点。 |
| 固定尺寸导致不同设备半径错误 | 高 | 从实际 LayoutBuilder 约束读取宽高，并将尺寸影响纳入 query key；增加窄屏/大屏测试。 |
| 高德候选页不足，空间稀疏后 marker 太少 | 中 | 先限制在现有 20 条候选，统计/测试不足场景；只在必要时受控请求第二页并合并去重。 |
| 贪心网格选择偏向中心或高分密集区 | 中 | 先按评分排序但按空间 cell 占位，使用中心距离和稳定 id tie-break；测试多区域代表点。 |
| 相机快速移动导致旧响应覆盖新结果 | 高 | 保留 request id、query key、debounce；多页请求必须共享 generation。 |
| Marker id 每次重建造成闪烁或点击错位 | 高 | selection key + marker source 缓存；每次重建同步清空并重建 id 映射；不得使用地点 id 假设插件可指定 Marker id。 |
| 过滤 marker 同时误伤结果抽屉/详情 | 中 | marker selection 与 `visiblePlaces` 分离；widget 测试断言列表仍保留原始结果。 |
| 修改共享 `AmapSurface` 影响行程小地图 | 中 | 优先只改 ExplorePage；若改公共回调，运行 trip route/小地图相关测试并保持默认参数兼容。 |
| 工作区已有未提交改动被覆盖 | 高 | 开始前保存/读取 diff，以当前工作树为基线；只编辑本计划列出的必要文件，不 reset/checkout。 |

## 8. 验证命令

在 `apps/mobile` 目录执行：

```bash
flutter test test/explore/map_marker_selection_test.dart
flutter test test/explore/map_viewport_test.dart
flutter test test/explore/explore_page_test.dart
flutter test test/places/place_search_controller_test.dart
flutter test

dart format --set-exit-if-changed lib test
flutter analyze
```

如变更 Supabase Edge Function 或迁移：

```bash
# 按仓库现有 Supabase 本地/部署脚本执行，先 dry-run 或只读核对
# 验证 places-search 的 around 参数、评分字段、分页、缓存 key 和错误码
# 不要在未确认线上迁移状态时直接执行破坏性 SQL
```

真机/模拟器手工验证（若环境可用）：

- 探索页首次进入、同意地图合规声明后显示底图；
- 拖动/缩放停止后请求范围随 zoom 和实际地图尺寸变化；
- 同一网格不会出现明显重叠 marker；高评分地点在同区域优先；
- 没有合法高德 `rating` 的美食 POI 不显示 marker；非美食 POI 同样不显示 marker，但关键词结果抽屉仍保持原始结果语义；
- 快速连续移动地图后最终只显示最新视野结果；
- 点击 marker 仍打开正确地点详情，收藏/加入行程保持正常；
- 大小不同的设备或旋转/布局变化不崩溃、不出现幽灵坐标。

## 9. 验收标准

- [ ] 纯 Dart 选择策略有独立测试，关键业务逻辑覆盖率达到项目要求（至少 80%）。
- [ ] 只有同时满足“美食类别 + 有效坐标 + 高德合法 `rating`”的地点能进入自动 marker 集合；无评分、空评分、解析失败、非有限值或超出 0～5 的地点全部排除。
- [ ] 合格地点严格按高德 `rating` 降序参与空间选择；同分使用中心距离和地点 id 稳定决胜，不存在评分缺失降级路径。
- [ ] marker 数量由实际地图宽高/marker footprint 动态计算，有明确 min/max，永不超过候选数。
- [ ] 地图宽高和 zoom 会影响周边查询半径与/或候选策略 key；生产路径不再固定使用 `360 x 640`。
- [ ] 空间稀疏结果稳定、可复现，地图视觉上不会出现明显重叠；高分集中时仍尽量覆盖不同空间区域。
- [ ] 关键词结果列表与详情/收藏/行程行为保持原有语义；筛选系统没有新增用户可见控件。
- [ ] 保留现有防抖、缓存、乱序响应、失败保留旧结果和鉴权边界。
- [ ] 若扩展评分/分页契约，客户端、Edge Function、缓存 key、RPC/迁移和测试全部同步；不修改历史迁移，不暴露高德 Key，不放开公共表写权限。
- [ ] `dart format`、`flutter analyze` 和相关/全部 Flutter 测试通过；真机验证结果与限制如实记录。
- [ ] 完成 code-reviewer 与 security-reviewer 审查，Critical/High 问题全部处理或明确阻塞。

## 10. 交给 implementation agent 的执行提示

请按 Task 0 → Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6 顺序执行。先测试后实现；高德 `rating` 接入与无评分强制排除是不可跳过的完成条件；不要为了满足“数量动态”而无条件增加请求页数；不要修改 `AmapSurface` 的业务职责。完成后返回：

1. 实际修改文件及每个文件的职责；
2. 评分字段/合规核对结论；
3. marker 选择策略的常量与复杂度；
4. 测试和分析命令的完整输出摘要；
5. 尚未解决的真实阻塞或设备验证限制。
