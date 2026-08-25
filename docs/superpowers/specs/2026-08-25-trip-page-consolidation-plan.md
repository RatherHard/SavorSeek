# 行程页面整合与生命周期设计

**日期**：2026-08-25
**范围**：行程页面的节点添加、编辑、删除流程整合，以及行程层面的完成 / 取消 / 删除操作
**前序文档**：`2026-08-24-trip-two-level-pages-design.md`（行程页面两级化重构）

---

## 1. 目标

本轮解决五件事：

1. 地点节点与普通节点的添加合并为**一个**表单入口。
2. 添加 / 修改节点时检索地点，结果在**小地图**上以标记呈现，可点选。
3. 节点的「改期」与「编辑」合并为**一个**表单、**一次**写入。
4. 移除节点的「取消」状态，节点只保留删除。
5. 行程层面新增**完成 / 取消 / 删除**三个操作。

第 4、5 条要求改动 Supabase 表约束与 RPC，因此下一节先梳理两张表的状态设计现状。

---

## 2. 现状梳理：两张表的状态设计

动手前对 `trips.status` 与 `trip_items.status` 做了完整审计（读 `20260821000002_itinerary_schema.sql` 与 `20260824000008_timezone_and_item_lifecycle.sql` 的全部 trigger）。结论：问题不在于两列互相污染，而在于**两列各有一半是死的**。

| | `trips.status` | `trip_items.status` |
|---|---|---|
| 声明值 | draft / confirmed / in_progress / completed / cancelled | planned / completed / skipped / cancelled |
| 转换约束 | 有，`validate_trip_row` 强制三条转换链 | 无转换链，只有「终态冻结」判断 |
| 写入方 | **无任何 RPC 写它** | `cancel_trip_item` / `restore_trip_item` 写 cancelled ↔ planned |
| 实际分布 | 全部永久停在 `draft` | planned / cancelled 两种 |
| 不可达值 | confirmed、in_progress、completed、cancelled | `skipped` |

### 2.1 `trips` 的状态机是一套没有司机的方向盘

`validate_trip_row` 强制的转换图是：

```
draft ──→ confirmed ──→ in_progress ──→ completed
  │           │              │
  └───────────┴──────────────┴──────────→ cancelled
```

但 `create_trip` 插入 `draft` 之后，**没有任何 RPC 再碰过这一列**。它不是设计混乱，是从未接线——状态机按想象中的完整流程写好了，而那个流程的前两步（确认行程、开始行程）从来没有实现。

这直接解释了本轮的第一个阻塞点：**不存在 `draft → completed` 转换**，而线上每个行程都是 `draft`。若不放宽，「完成」按钮会在每个行程上失败。

### 2.2 `trip_items.status` 一列塞了两个正交的轴

`20260824000008` 的注释已经说穿这件事：`completed` / `skipped` 是「已经发生过的事实」，`cancelled` 是「用户当前不打算去」。前者回顾，后者前瞻。塞进一列的代价是可观测的：

- 终态判断被迫拆成两个分支——`old.status in ('completed','skipped')` 一条，`old.status = 'cancelled'` 又一条（`20260824000008:157-164`）。
- 唯一索引 `trip_items_active_position_uq` 不得不带谓词 `where status <> 'cancelled'`（`20260821000002:111-112`）。
- 于是**每一处计算 position 的代码都必须记得过滤 cancelled**，共四处：`reschedule_trip_item`、`restore_trip_item`、`add_trip_item` 路径、`batch_*`。这是一个没有类型系统保护的隐式契约。

因此第 4 条需求（移除节点取消）不是在破坏设计，而是在**修**它。删掉 `cancelled` 后：这一列只剩一个轴（这件事有没有发生）、终态分支合并回一条、唯一索引的谓词消失、四处 position 计算的隐藏耦合一起消失。

### 2.3 两张表同名不同义，且从不互相约束

`completed` / `cancelled` 在两张表里都出现，含义不同：`trips` 表示计划的生命周期，`trip_items` 表示这件事是否发生过。更值得注意的是——**当前一个 `cancelled` 的行程，它的节点完全可编辑**，两列之间没有任何关联逻辑。

本轮定下的「完成后只读、取消后仍可编辑」是这两列之间的**第一条耦合**。它必须实现在一处，否则会散落到六个 RPC 里各写一遍。

### 2.4 已知死 schema（本轮不动）

- `trips.archived_at`：无写入、无读取、无 RLS 引用。
- `trip_items.status = 'skipped'`：无写入方。

两者都不阻塞当前工作，顺手删除属于无关重构。在此记录以免后来者误以为有人在用。

---

## 3. 数据库设计

单个新迁移文件：`supabase/migrations/20260825000011_trip_page_consolidation.sql`。

> **注意**：本仓库的迁移**不会自动上库**。写完后须手动应用，并按 §8 的核对脚本对账。

### 3.1 新增 `edit_trip_item`（合并写入）

一次事务内同时改 `title` / `notes` / `trip_day_id` / `planned_start_at` / `planned_end_at` / `time_slot`，**只自增一次 revision、只用一个幂等键**。

为什么新写一个而非客户端顺序调两个：顺序调用的第二次失败会留下「时间改了内容没改」的半成品，撤销要拆成两步，且 revision 冲突窗口翻倍。

跨天时 `position` 由函数按目标日实际占用计算，不接受调用方传入——客户端算出的值在并发下必然过期（沿用 `reschedule_trip_item` 的既有规则）。

`update_trip_item` 与 `reschedule_trip_item` **保留不动**，供探索页「加入行程」及后续 Agent 调用。

错误码沿用现有约定：`28000` 未认证 / `42501` 行程不存在或无权 / `P0002` revision 冲突 / `22023` 请求内容不合法。

### 3.2 废弃节点级 cancelled

- `drop function` — `cancel_trip_item`、`restore_trip_item`、`batch_cancel_trip_items`。
- **数据迁移** — 把 `status = 'cancelled'` 的节点改回 `planned`，并按 `planned_start_at` 顺序重排到当天末尾的 position。选择恢复而非删除：直接删会把用户可能还想恢复的项静默销毁；恢复后用户下次打开会看到它们回到计划里，而它们本来就是可反悔的意图。
- `trip_items_status_ck` 收窄为 `('planned', 'completed', 'skipped')`。
- `trip_items_active_position_uq` 重建为**不带谓词**的普通唯一索引 `(trip_day_id, position)`。
- `validate_trip_item_row` 删掉 `cancelled → planned` 分支，终态判断合并回 `old.status in ('completed','skipped')` 一条。
- 清理 `reschedule_trip_item` / `update_trip_item` 中的 `status <> 'cancelled'` 过滤与相关注释。
- `batch_delete_trip_items` 保留。

### 3.3 行程生命周期三个 RPC

`complete_trip` / `cancel_trip` / `delete_trip`，签名与现有 RPC 同构：`p_trip_id` + `p_expected_revision` + `p_idempotency_key`，`security definer`，错误码同 §3.1。

`delete_trip` 直接 `delete from public.trips where id = ... and user_id = auth.uid()`，靠 `trip_days` / `trip_items` 上既有的 `on delete cascade` 清空子表，返回 `deleted_count`。

### 3.4 调整一：放宽 `trips` 状态机，但只接线三个值

`validate_trip_row` 的转换表新增两条：`draft → completed`、`confirmed → completed`。

`cancel_trip` **不需要**改转换表：`draft → cancelled` 在既有状态机里已经存在（§2.1 的转换图），从任意非终态取消都是合法的。本节的两条新增只为「完成」服务。

**不删** `confirmed` / `in_progress`：删除要改 check 约束，对用户无任何收益，而 Agent 后续接「确认行程 / 开始行程」时会用到。改为在迁移注释里写明**当前 `confirmed` / `in_progress` 按设计不可达**，避免下一个读代码的人以为是漏了入口。

### 3.5 调整二：「完成即只读」收进一个函数

新增 `public.assert_trip_writable(p_trip_id uuid)`：若目标行程 `status = 'completed'` 则抛 `22023`。

在六个节点写入 RPC 锁到 trip 行后各调用一次：`add_trip_item`、`edit_trip_item`、`reschedule_trip_item`、`update_trip_item`、`delete_trip_item`、`batch_delete_trip_items`。

这是 §2.3 指出的两列之间**唯一的耦合点**，只应有一处实现，不把 `if trip_row.status = 'completed'` 抄六遍。

已取消的行程**不拦**——用户可能取消后仍想整理记录。

### 3.6 已知限制

`completed` / `cancelled` 对 `trips` 仍是终态，本轮**不提供**「重新启用」入口。误点「完成」的用户无法回退。记录在此，待后续需求确认。

---

## 4. 模型层（Dart）

`trip_models.dart`：

- `TripItemStatus` 去掉 `cancelled`；`isTerminal` 语义随之简化。
- 新增 `TripStatus` 枚举（draft / confirmed / inProgress / completed / cancelled，`wireName` 与库对齐）。
- `TripPlan` 与 `TripSummary` 各新增 `status` 字段——**两者目前都不含该字段**，需同步改 `trip_mapper.dart` 的解析。
- `TripPlan.routeStops` 去掉取消项过滤。
- 新增 `TripPlan.isReadOnly => status == TripStatus.completed`。

---

## 5. 统一添加表单

`add_stop_sheet.dart` 成为**唯一**添加入口。表单结构：

1. 顶部一行「关联地点（可选）」，点击唤起地点检索子表单（§6）。
2. 选中后自动填入标题（仍可改），并显示可清除的地点芯片。
3. 其余为日期、开始时间、时长、备注（沿用现有字段与校验）。

提交时按是否绑定地点分流到 `TripStopActions.addPlace` / `addBreak`。详情页原有的两个添加入口（`_addStop` 与 `_addPlace`）合并为一个。

地点绑定**只在添加时提供**，编辑不改绑定关系——`place_visit` 与 `break` 的库端约束不同（前者强制要求快照），中途切换类型需要额外的 RPC 语义，YAGNI。

---

## 6. 检索小地图

`pick_place_sheet.dart` 在结果列表上方插入 `AmapSurface`（已支持 `markers` 与 `onMapTap`），为当前结果集中**有坐标**的地点各打一个标记。

**点标记或点列表行都只是「选中」**，不直接提交：相机移到该点、列表行高亮、底部出现该地点卡片与「确认」按钮。地图上误触直接写库太脆。

退化路径：

- 无坐标的结果不打点，但仍在列表中可选（沿用现有 `location_off` 图标提示）。
- 未取得高德合规同意，或结果全无坐标时，**不渲染地图**，退回纯列表，不留灰框。

需把 `AmapConsent` 从详情页透传进本表单（当前 `showPickPlaceSheet` 只接 `placeRepository` 与 `city`）。

---

## 7. 合并编辑表单与行程操作

### 7.1 编辑

`edit_stop_sheet.dart` 扩展为：标题 + 备注 + 日期 + 时间 + 时长。保存走 `editTripItem`。

`StopAction` 枚举里 `reschedule` 与 `edit` 合并为一个 `edit`，`cancel` / `restore` 删除。

撤销随之变干净：一次逆向 `editTripItem` 即可还原全部五个字段，不再需要 `reschedule` 与 `updateItem` 两条独立的撤销路径。

`schedule_picker_sheet.dart` **保留**——探索页的「加入行程」仍在用，其 `formatLocalDate` / `formatWallClock` / `formatDuration` 等格式化辅助函数继续共享。

### 7.2 行程操作

详情页 AppBar 菜单在「更改行程时区」之外加入完成 / 取消 / 删除。

- 完成与删除各带二次确认；删除的确认文案说明**级联清空且不可撤销**。
- 删除成功后 `pop` 回列表页。
- `isReadOnly` 时隐藏添加按钮与节点菜单，顶部显示锁定说明条。
- 列表页为每个行程显示状态标记。

### 7.3 调整三：文件划分与瘦身

行程级写入不属于「节点动作」，因此：

- 新建 `trip_lifecycle_actions.dart`（复用 `TripStopActions` 的忙碌互斥 / 冲突重载 / outcome 广播模式），而非塞进 `TripStopActions`。
- 确认弹窗与菜单抽到 `trip_lifecycle_menu.dart`。

顺带把 `trip_repository.dart`（1100+ 行）中的 `InMemoryTripRepository` / `UnavailableTripRepository` / `DemoTripRepository` / `TripPlanSummary` 切到 `trip_repository_fakes.dart`。理由：本轮要往这个文件加四个方法，不切会继续超出项目规范的 800 行上限。

---

## 8. 测试与验证

**新增**：`supabase/snippets/verify_trip_page_consolidation.sql` —— 核对新 RPC 是否已上库（查 `pg_proc`）、旧 RPC 是否已 drop、check 约束与唯一索引是否已改、`cancelled` 节点是否已清零。

**需改动的既有测试**：

| 文件 | 原因 |
|---|---|
| `trip_item_lifecycle_test.dart` | cancel / restore 移除 |
| `trip_stop_actions_test.dart` | 同上，且新增 editTripItem |
| `trip_undo_test.dart` | 撤销路径合并 |
| `trip_batch_ops_test.dart` | batchCancel 移除 |
| `trip_route_data_test.dart` | routeStops 不再过滤 cancelled |
| `trip_mapper_timezone_test.dart` | 含 cancelled 断言 |
| `trip_detail_page_test.dart` | 菜单项变化、只读态 |

**新增测试**：合并添加表单的两条分流、检索小地图的选中/退化、合并编辑表单的五字段提交、行程三操作的成功与冲突路径、只读态下入口隐藏。

---

## 9. 实施顺序

1. 迁移 `20260825000011` + 核对脚本，手动上库并对账。
2. 模型层（`TripStatus`、`TripPlan.status`、`trip_mapper`）。
3. 仓库层（`editTripItem` / `completeTrip` / `cancelTrip` / `deleteTrip`；移除 cancel / restore / batchCancel）+ `trip_repository_fakes.dart` 切分。
4. `TripStopActions` 调整 + `trip_lifecycle_actions.dart`。
5. 合并编辑表单。
6. 统一添加表单。
7. 检索小地图。
8. 详情页与列表页接线（菜单、只读态、状态标记）。
9. 测试补齐，`dart analyze` + `flutter test` 全绿。

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-08-25 | 初始版本：状态设计审计、数据库迁移方案、五项整合的设计与实施顺序 |
