# 行程页重构：多行程 · 节点 · 路线小地图 + 待办三项

## 问题定位（已确认）

**入口消失的根因**：`trip_page.dart:474` 的 `_TripEmpty` 持有**唯一**一个「创建行程」按钮；
`_TripLoaded`（第 576 行）只渲染了时区图标 + 每项的 `PopupMenuButton`。因此一旦
`loadPlan()` 返回非空，`AnimatedSwitcher` 切到 `_TripLoaded`，创建/添加入口全部消失。

同时 `SupabaseTripRepository.loadPlan()`（第 124-129 行）`.limit(1)` 只取最近更新的
一个行程——**多行程在数据层就没有被读出来**，不只是 UI 缺开关。

**小地图的数据缺口**：`_planSelect`（第 18-27 行）没有 select `place_snapshot`，
`TripMapper.stopFromRow` 也不读它，所以 `TripStop` 目前**没有坐标**。
`TripPlan.mapState` 存在但从未被赋值为 `available`。

**插件能力边界**：`amap_map 1.0.15` 只有 `AMapWidget` / `Marker` / `Polyline` / `Polygon`，
**不含任何路径规划 API**（已核对 pub cache 的 `lib/src/types/`）。真实路网必须走
高德 Web 服务 API，按已确认决策放在 Edge Function（Key 不下发客户端）。

## 阶段一：修复入口消失（可独立验证）

改 `trip_page.dart`：把 `_TripLoaded` 从「只读时间表」改为带完整操作区。

- `_TripHeader` 增加一个 `PopupMenuButton`（`Icons.more_horiz`）聚合行程级操作：
  编辑行程信息 / 更改时区 / 新建行程。时区图标并入菜单，不再单独占位。
- 新增 `FloatingActionButton.extended`「添加节点」。`TripPage` 目前被
  `app_shell.dart:47` 放在 `Scaffold.body` 里，没有自己的 Scaffold——用
  `Stack` + `Positioned` 在页面右下角放按钮，避免改动 AppShell 的 Scaffold 结构。
- 为 `_TripEmpty`/`_TripLoaded` 共用的「创建行程」回调补 widget 测试：断言
  载入态下三个入口都存在（当前测试只覆盖了空态）。

## 阶段二：多行程

**数据层**（`trip_repository.dart`）：
- `TripRepository` 新增 `Future<List<TripSummary>> listTrips()`，select
  `id, title, timezone, start_date, end_date, revision, updated_at`（不取嵌套项，
  列表不需要），按 `updated_at desc`。
- `loadPlan()` 增加可选 `String? tripId` 参数：给定时按 id 取，为空时保持
  「最近更新的一个」的现有行为（向后兼容 `InMemoryTripRepository` 与全部现有测试）。

**状态层**（`trip_controller.dart`）：
- `TripLoaded` 增加 `trips`（全部行程摘要）与 `selectedTripId`。
- `TripController` 增加 `selectTrip(String id)`：先 `listTrips()` 再 `loadPlan(tripId:)`。
- 选中项在 controller 内存中保持，切页（`IndexedStack`）不丢失。

**UI**：`_TripHeader` 的标题改为可点的行程切换器（`Icons.expand_more`），
弹出 `_TripSwitcherSheet` 列出全部行程 + 底部「新建行程」。

## 阶段三：节点坐标与路线小地图

**读出坐标**：
- `_planSelect` 加 `place_snapshot`。
- `TripStop` 增加 `latitude` / `longitude`（可空，成对）；
  `TripMapper.stopFromRow` 从 `place_snapshot` 解析，沿用 `PlaceSnapshot` 的校验语义
  （gcj02，与底图同基准，无需转换）。
- `TripMapper.planFromRow` 按「有 ≥2 个带坐标的节点」把 `mapState` 置为 `available`。

**小地图组件** `trip/trip_route_map.dart`：
- 扩展 `AmapSurface`：新增 `polylines`、`initialCamera`、`gestureRecognizers` 可配置
  三个参数（默认值保持现有行为，`explore_page.dart` 不受影响）。
  必须让手势可配：现有 `EagerGestureRecognizer` 会吞掉父级 `CustomScrollView` 的纵向滚动。
- 小地图内禁用滚动/缩放手势，点击整块跳转到全屏路线视图——固定高度里的手势与
  页面滚动必然冲突，只读缩略图 + 全屏查看是唯一不别扭的解法。
- 节点按 `position` 顺序编号打点，`Polyline` 连接。
- `Marker`/`Polyline` 构造即生成 id，必须按 `explore_page.dart:257` 的既有做法缓存，
  否则每帧全删全插会闪烁。
- **合规**：`AmapConsent` 目前是 `ExplorePage` 的实例字段（第 42 行），行程页拿不到。
  上提到 `AppDependencies`，两页共享同一实例；未同意时小地图位置显示
  `AmapConsentNotice`，不静默白屏。

**真实路网** `supabase/functions/trip-route/`：
- 新函数，结构对齐 `places-search`：`index.ts` + `amap.ts` + 复用 errors 形状。
  调 `/v3/direction/walking`（默认）与 `/driving`，按 `trips.default_travel_mode` 选。
- 沿用既有安全约定：显式 `requireUser()`（Kong 只校 anon key，见 places-search 注释）、
  Key 只读服务端 `AMAP_WEB_SERVICE_KEY`。
- 高德 direction 接口一次只接受一组起终点，N 个节点需 N-1 次请求；在函数内串行
  并合并 polyline，客户端只发一次请求。
- 缓存：新建 `trip_routes` 表按 (起点,终点,mode) 哈希缓存，TTL 7 天（路网变化远慢于 POI）。
- **降级**：函数不可用/未配置 Key 时，客户端回退到直线连接，并在地图上标注
  「显示为直线连接」，不让整个小地图失效。

## 阶段四：待办三项

**1. 创建行程时选时区**（`create_trip_sheet.dart`）
- 加一个 `_FieldTile` 复用 `showTimezonePickerSheet`，`CreateTripDraft` 增加 `timezone`
  字段，`_createTrip` 透传给已支持 `p_timezone` 的 `createTripWithDays`。
- 无需迁移（待办文档第 17 行已确认）。

**2. 批量操作** — 需新迁移 `20260824000009_batch_trip_item_ops.sql`
- 新增 `batch_cancel_trip_items` / `batch_delete_trip_items`，接受 `p_trip_item_ids uuid[]`，
  单事务内完成、**只递增一次 revision**（与数据模型文档第 326 行的既有约定一致）。
- 沿用现有 `itinerary_idempotency_result` 机制与 `P0002` 冲突码；
  `revoke all` 后仅 `grant execute to authenticated`，与既有 8 个 RPC 一致。
- UI：`_TripLoaded` 增加多选态（长按进入），底部操作条批量取消/删除。

**3. 统一撤销入口**
- 新增 `TripUndoAction`：写入前留存快照（改期需原 `trip_day_id` 与起止时刻），
  成功后的 `SnackBar` 挂 `SnackBarAction(label: '撤销')`。
- 覆盖取消（→restore）、改期（→用原值再 reschedule）、加入行程（→delete）。
- 硬删除不纳入（记录已不存在，待办文档第 41 行已说明），确认框保持现状。

## 测试

按 `test/trip/` 既有风格补：
- `trip_page_test.dart`：载入态三个入口存在（回归本次 bug）、行程切换器可打开。
- `trip_multi_trip_test.dart`：`listTrips` + `selectTrip` 切换后 plan 随之更新。
- `trip_route_map_test.dart`：坐标缺失/单点/多点三种情形下小地图的呈现分支
  （用假 repository，不初始化 SDK）。
- `trip_mapper_test.dart`：扩充 `place_snapshot` 坐标解析与 `mapState` 派生。
- `trip_batch_ops_test.dart`、`trip_undo_test.dart`：成功/冲突/失败三分支。
- 每阶段结束跑 `flutter analyze` + `flutter test`。

## 文档

按 CLAUDE.md 要求：更新 `docs/开发日志.md`（倒序、含完成内容/验证结果/后续计划），
从 `docs/待办.md` 移除已完成的三项并更新版本历史表。新增迁移与 Edge Function
需在 `docs/architechture/` 对应文档补记。不新增其他文档。

## 交付顺序

阶段一独立提交（修 bug，最小改动）→ 二 → 三 → 四，每阶段 analyze + test 通过后再进下一阶段。
