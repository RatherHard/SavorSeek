# 行程页面两级化重构设计

## 背景与目标

现状：行程 tab 直接挂 `TripPage`（1676 行），单页内同时承担行程选择（点标题弹 `trip_switcher_sheet`）与节点管理。行程数变多后，「在看哪一个」与「怎么换一个」都藏在标题的下拉图标里，且这一个文件同时装着展示、写入编排与多选态。

目标：改为两级结构。一级 `TripListPage` 选择行程，二级 `TripDetailPage` 查看/编辑/添加/删除节点，并保留小地图路径可视化。同时新增节点标题与备注的编辑能力。

## 范围

本设计覆盖两件事：

- **A —— 两级页面重构。** 能力等同现状：改期、取消、恢复、删除、批量取消/删除、撤销、改行程时区、添加自由安排节点、小地图与全屏路线。
- **B —— 节点内容编辑。** 新增修改节点标题与备注的能力，需要一个新的服务端 RPC。

**不在本次范围：**

- **C —— 同日内拖拽排序。** 独立需求，另行设计。原因：`trip_items_active_position_uq` 是 `(trip_day_id, position) where status <> 'cancelled'` 的部分唯一索引，Postgres 的唯一索引逐行检查且不可延迟（partial unique 只能是索引、拿不到 `DEFERRABLE`），加上 `trip_items_position_ck check (position >= 0)` 挡住了用负数做暂存区，重排必须两阶段写入（先整体偏移到无冲突区间，再落最终值）。这套服务端逻辑的验证面独立于本次重构。
- 新建 SQL 测试工具链（pgTAP / `supabase test db`）。当前 `supabase/` 下无测试目录，本次沿用既有做法，不引入新工具链依赖。

## 方案选择

采用「列表页进 tab，详情页 push 到根 Navigator」。

被否的两个备选：

- **详情页嵌在 trip tab 内部（嵌套 Navigator）。** 好处是 `AppShell` 的顶部主导航常驻、`IndexedStack` 的状态保持语义不变。代价是要自行处理 Android 物理返回键的层级拦截，且 `AppShell` 从「三个页面」变成「一个带路由的壳」。为留住主导航而引入一层路由复杂度，不划算。
- **只拆页面，不抽写入编排。** 详情页会达到约 1200 行，超过项目规范的 800 行上限；且 revision 冲突处理、撤销取原值这类最易错的逻辑仍然只能靠 widget 测试间接覆盖。等于把 1676 行的问题平移成 1200 行。

采用方案的已知代价：详情页盖住 `AppShell` 的顶部主导航，在详情页内无法直接切到探索/我的，需先返回。这与两级结构的语义一致——进去做事、做完返回。

## 导航结构

```
AppShell (tab: 行程)
  └── TripListPage                    ← 替换现在的 TripPage
        │ 点击行程卡片
        ↓ Navigator.of(context).push  （根 Navigator，盖住 AppShell）
      TripDetailPage(tripId: ...)     ← 自带 Scaffold + AppBar + 返回键
```

返回列表时列表重新 `load()`：详情页里改了标题或删了节点，列表上的天数与更新时间都可能变。实现方式是 `await push(...)` 之后直接调 `_controller.load()`，不引入额外的通知机制。

## 文件变动

### 新增

| 文件 | 职责 |
|------|------|
| `apps/mobile/lib/features/trip/trip_list_page.dart` | 一级页：行程卡片列表，loading/empty/error/未登录四态，新建行程入口 |
| `apps/mobile/lib/features/trip/trip_detail_page.dart` | 二级页：页头 + 小地图 + 按天时间轴 + 多选态与浮动按钮 |
| `apps/mobile/lib/features/trip/trip_stop_actions.dart` | 写入编排：改期/取消/恢复/删除/批量/撤销/改时区/加节点/改标题备注 |
| `apps/mobile/lib/features/trip/edit_stop_sheet.dart` | B 的表单：修改节点标题与备注 |
| `supabase/migrations/20260824000010_update_trip_item.sql` | `public.update_trip_item` RPC |

### 修改

- `apps/mobile/lib/app/navigation/app_shell.dart` —— `TripPage` → `TripListPage`
- `apps/mobile/lib/features/trip/trip_controller.dart` —— 去掉 `trips` 字段与 `selectTrip`，改为构造时传入 `tripId`（详情页只服务一个行程）；新增 `TripDetailGone` 状态，见「错误处理」
- `apps/mobile/lib/features/trip/trip_repository.dart` —— `TripWriter` 接口新增 `updateTripItem`，`SupabaseTripRepository` 实现之

### 删除

- `apps/mobile/lib/features/trip/trip_page.dart` —— 其中的展示型 widget 按归属搬迁：
  - 搬进详情页：`_TripHeader`、`_TripDayTimeline`、`_TimelineStop`、`_StopCard`、`_StopMenu`、`_BatchActionBar`、`_MapFallback`、`_MapPatternPainter`、`_LoadingBlock`、`_TripLoading`
  - 搬进列表页：`_TripEmpty`、`_TripError`、`_TripSignInPrompt`
  - 顶层枚举 `StopAction` 与 `TripAction` 随详情页迁移
- `apps/mobile/lib/features/trip/trip_switcher_sheet.dart` —— 列表页取代其职责

### 预估体量

| 文件 | 行数 |
|------|------|
| `trip_list_page.dart` | ~320 |
| `trip_detail_page.dart` | ~600 |
| `trip_stop_actions.dart` | ~420 |
| `edit_stop_sheet.dart` | ~180 |

详情页 600 行在 800 上限内，其余均为展示型 widget。若实现时超过 800 行，把时间轴那组 widget 再拆一个 `trip_timeline.dart`。

### 小地图

沿用现状：小地图关闭手势，点击进 `TripRoutePage` 全屏。理由是详情页比现在的单页更需要纵向滚动（节点列表更长），小地图开手势会与页面滚动争夺同一个纵向拖拽。缩放与平移只在全屏视图提供。

## 写入编排抽取

`_TripPageState` 中约 460 行写入编排从 UI 抽出，成为不依赖 `BuildContext` 的类。

```dart
/// 行程写入编排。
///
/// 从 UI 抽出而非留在 State 中：九种写入共享同一套 revision 冲突处理、忙碌互斥
/// 与撤销取值规则，这些规则的正确性不该只靠 pumpWidget 间接覆盖。
class TripStopActions {
  TripStopActions({
    required TripWriter writer,
    required Future<void> Function() reload,
  });

  /// 写入进行中，用于阻止重复提交。
  ValueListenable<bool> get isBusy;

  /// 每次写入的结果：成功文案 + 可选的撤销闭包，或失败原因。
  Stream<TripActionOutcome> get outcomes;

  Future<void> reschedule({...});
  Future<void> cancel({...});
  Future<void> restore({...});
  Future<void> delete({...});        // 二次确认由 UI 负责，此处只执行
  Future<void> batchCancel({...});
  Future<void> batchDelete({...});
  Future<void> changeTimezone({...});
  Future<void> addBreak({...});
  Future<void> updateItem({...});    // B 新增
  Future<void> undo(TripUndo undo);
}
```

### 无状态：`plan` 每次调用传入

`TripStopActions` 不持有 `TripPlan`。`revision` 是乐观并发控制的核心，只允许有一个来源——`TripController` 的当前状态。内部再存一份当前 plan 会多出一处需要与 `TripController` 同步的状态，两处 `revision` 不一致时的 bug 很隐蔽。代价是方法签名较长。

### 必须原样保留的三条既有规则

这些是现有代码注释里已记录的坑，抽取时不得丢失：

1. **批量操作走批量 RPC，不循环单项。** 每次单项写入都会自增 `trips.revision`，循环到第二次时手里的 `expected_revision` 已过期，必然收到 `P0002`。**恢复是例外**：`restore_trip_item` 没有批量版，因此批量取消的撤销必须逐项调用，且每次用上一次返回的 `revision` 往下走，沿用同一个值会从第二项起报 `P0002`。
2. **撤销所需的原值必须在写入前留存。** 写入成功后再读已是新值。改期的撤销需要原 `tripDayId` 与原起止时刻；添加节点的撤销需要新项 id，而它只能从写入结果取得，故用一个可变量在写入闭包与撤销闭包之间传递（撤销闭包在写入成功后才会被调用，届时已被赋值）。
3. **撤销使用「撤销时」的最新 `revision`。** 不是被撤销那次操作所用的旧值——后者早已过期。

### 职责边界

| 归属 | 内容 |
|------|------|
| `TripStopActions` | revision 冲突 → 触发 reload；忙碌互斥；撤销闭包构造；错误分类 |
| `TripDetailPage` | 删除的二次确认对话框；SnackBar 呈现；多选态；表单弹出 |

分界线是「是否需要 `BuildContext`」：需要的留在 UI，不需要的进 `TripStopActions`。

### 结果通道用 Stream

写入结果要变成一条 SnackBar，而 SnackBar 需要 `ScaffoldMessenger`（即 context）。用 `Stream<TripActionOutcome>` 让详情页 `listen`，比给每个方法都传 `onSuccess`/`onError` 回调干净，也让「撤销」这个附带动作统一挂在 outcome 上而非每个方法各接一次。

```dart
sealed class TripActionOutcome {
  const TripActionOutcome();
}

final class TripActionSucceeded extends TripActionOutcome {
  const TripActionSucceeded(this.message, {this.undo});
  final String message;
  /// 非空时 SnackBar 显示「撤销」。
  final TripUndo? undo;
}

final class TripActionFailed extends TripActionOutcome {
  const TripActionFailed(this.message);
  final String message;
}
```

`TripUndo` 包装 `Future<void> Function(TripWriter writer, int revision)`，与现有签名一致。

## `update_trip_item` RPC 契约

### 签名

```sql
create or replace function public.update_trip_item(
  p_trip_id uuid,
  p_expected_revision bigint,
  p_idempotency_key uuid,
  p_trip_item_id uuid,
  p_title text,
  p_notes text
) returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
```

参数顺序与既有单项 RPC（`cancel_trip_item`、`reschedule_trip_item`）一致：`trip_id + expected_revision + idempotency_key` 三件套在前，目标 id 与业务字段在后。

### 语义决定

**只改 `title` 与 `notes`，不碰其他字段。** 时间用 `reschedule_trip_item`，状态用 cancel/restore/delete。一个 RPC 只负责一组字段，错误语义才好定义。

**两个参数都必填，不支持「传 null 表示不改」。** `notes` 的「清空」与「不改」都会想用 null 表达，二义性只能靠额外哨兵值解决。UI 侧本就是从预填当前值的表单提交，两个字段总是一起送。清空备注即传空串，表上的 `validate_trip_item_row` 触发器会执行 `nullif(btrim(new.notes), '')` 归一为 NULL。

**幂等哈希覆盖 `trip_item_id + title + notes`。** 同一个键配不同内容须报 `22023`（键复用但请求不同），与既有 RPC 一致。

**已取消的项允许编辑。** 已取消的项还可能被恢复，在恢复前顺手改备注是合理的。已完成与已跳过的项不可编辑——它们是历史事实，改标题会让记录与当时发生的事不符。

无需修改 schema：`title` 为 `varchar(120)`、`notes` 为 `varchar(1000)`，两者都不在 `is_place_locked` / `is_time_locked` / `is_order_locked` 的涵盖范围内；`validate_trip_item_row` 的 UPDATE 分支只拦终态项的 **status** 变更，本 RPC 不动 status，故通过。

### 校验与错误码

沿用既有约定，客户端现有的 `TripRepositoryErrorKind` 映射无需扩展：

| 情形 | errcode | 说明 |
|------|---------|------|
| 未登录 | `28000` | `auth.uid()` 为空 |
| 行程不存在或不属于本人 | `42501` | `for update` 取不到 |
| revision 不匹配 | `P0002` | 乐观并发冲突 |
| 项不存在或不属于本行程 | `42501` | 与批量版一致，不泄漏他人行程中是否存在该 id |
| 项处于 `completed` 或 `skipped` | `22023` | 已完成/已跳过是历史事实，不可编辑；已取消项可编辑 |
| 标题 btrim 后为空或超 120 字符 | `22023` | 提前显式检查，不依赖表约束报 `23514` |

### 事务结构

与既有单项 RPC 同构：

1. 校验 actor → 计算 request_hash → 查幂等结果（命中直接返回）
2. `select ... for update` 锁行程行，比对 `revision`
3. 校验目标项归属与状态
4. `update trip_items set title = btrim(p_title), notes = nullif(btrim(p_notes), '')`
5. `update trips set revision = revision + 1` —— 只递增一次
6. 存幂等结果，返回 `{trip_item_id, revision}`

标题的 btrim 在 RPC 内也做一次（虽然触发器会做），这样第 6 步之前的显式长度校验是对最终值做的。

### 客户端接口

```dart
Future<TripWriteResult> updateTripItem({
  required String tripId,
  required int expectedRevision,
  required String tripItemId,
  required String title,
  String? notes,
});
```

撤销：逆操作是把原值写回，原值在写入前从 `stop.title` / `stop.note` 取。

### UI 连带变化

`_StopMenu` 当前对已取消项只给「恢复 / 删除」，需加入「编辑」。`completed` / `skipped` 项仍完全不显示菜单，与「不可编辑」一致。

## 数据流

```
TripListPage
  TripListController.load() → listTrips() → 摘要列表
  点卡片 → await Navigator.push(TripDetailPage(tripId))
        ← 返回后 TripListController.load()      // 详情页可能改了标题、删了节点

TripDetailPage
  TripController(repository, tripId: ...).load() → loadPlan(tripId) → TripPlan
  用户操作 → TripStopActions.xxx(plan: ..., ...)
           → TripWriter RPC
           → reload 回调 → TripController.load()
           → outcomes 流 → SnackBar（含「撤销」）
```

`TripListController` 只取摘要不取行程项：列表页只显示标题与日期区间，为此把每个行程的全部节点都拉下来会让请求量随行程数线性膨胀。节点由详情页按需加载。

## 错误处理

### 详情页的 `TripDetailGone` 状态

`TripController` 现有实现在 `loadPlan(tripId)` 返回 null 时映射到 `TripEmpty`。单页时代这是对的（「你还没有行程」），但在详情页里 null 意味着「这个行程没了」——可能是另一台设备删的，也可能列表数据已过期。此时显示「暂无行程」是误导。

详情页把 null 视为独立状态 `TripDetailGone`，呈现「此行程已不存在」加一个「返回列表」按钮。用户点击后 `pop`，列表页的 `load()` 会把它从列表摘掉。**不自动 pop**——无预警地弹回去，用户不知道刚才发生了什么。

### 其余状态

- `unauthenticated` → 登录引导。列表页与详情页都需要。
- `conflict`（`P0002`）→ 提示并自动重载，用户可重试。已在 `TripStopActions` 内统一处理。
- 其他 → 错误页加重试按钮。

### 未登录的语义

RLS 下未登录读取恒为空，这不是错误。现有 `TripPage` 已将其单独映射为 `TripError(kind: unauthenticated)` 并呈现登录引导，列表页沿用。

### 会话变化的订阅

列表页与详情页**都**订阅 `auth.userIdChanges`。行程数据是用户私有的，登出后仍留在屏幕上不合适；只让列表页订阅会留下一个「详情页显示已登出用户数据」的窗口，直到用户返回列表。多一处订阅的成本很低。

### 新建行程入口

从现在的页头溢出菜单移到列表页。这本就是列表层面的操作，放在列表页比藏在某个行程的页头里更合理。

## 测试

### 现有测试的处置

8 个测试文件直接构造 `TripPage(repository: ...)`，全部需要调整。

**改宿主即可（5 个）：** `trip_batch_ops_test.dart`、`trip_item_lifecycle_test.dart`、`trip_reschedule_test.dart`、`trip_undo_test.dart`、`trip_entry_points_test.dart`。这些测的是节点操作行为，把 `TripPage(repository:)` 换成 `TripDetailPage(repository:, tripId:)` 即可，断言基本不动——时间轴、卡片、菜单这些 widget 是搬迁而非重写。

`trip_entry_points_test.dart` 有一处例外：第 77 行断言 `find.text('新建行程'), findsNothing`（因 Fake 仓库不是 `SupabaseTripRepository`，故入口不出现）。新建行程移到列表页后，这条断言在详情页测试中变成恒真而无信息，应删除并在列表页测试中重建同等覆盖（无写入能力时不给出新建入口）。

**拆成两份（2 个）：**

- `trip_page_test.dart` → `trip_list_page_test.dart`（loading/empty/error/未登录四态）+ `trip_detail_page_test.dart`（plan 渲染、小地图回退）
- `trip_multi_trip_test.dart` → 现测切换器弹窗；切换器被删，改为测「列表页列出多个行程 + 点击进入正确的详情页」

**断言方式变（1 个）：** `apps/mobile/test/navigation/app_shell_test.dart:77` 的 `find.byType(TripPage)` → `TripListPage`。

### 新增测试

| 文件 | 覆盖 |
|------|------|
| `trip_stop_actions_test.dart` | 编排单测（不 pumpWidget）：冲突触发 reload；忙碌期间第二次调用被丢弃；批量取消的撤销逐项递进 revision；改期撤销使用写入前原值 |
| `trip_list_page_test.dart` | 四态渲染；点击卡片导航；返回后重新 load |
| `trip_detail_page_test.dart` | plan 渲染；`TripDetailGone` 态；登出切换到登录引导 |
| `edit_stop_sheet_test.dart` | 表单预填当前值；空标题不可提交；清空备注提交空串 |

错误码映射无需新增测试：`trip_error_mapping_test.dart` 按错误码（而非按 RPC）覆盖 `translatePostgrestError`，`update_trip_item` 复用的 `28000` / `P0002` / `42501` / `22023` 均已在其中。

`trip_stop_actions_test.dart` 是本次拆分最直接的收益：上表前四条现在只能靠 `pumpWidget` 整页间接覆盖。

### RPC 侧验证

不新建 SQL 测试框架。`update_trip_item` 靠客户端集成测试与手动验证覆盖，需验证的点：

- `completed` / `skipped` 项被拒（`22023`）
- `cancelled` 项可编辑
- 幂等键复用但内容不同报 `22023`
- `revision` 只 +1

### 验证方式

`flutter test` 全绿，`dart analyze` 无警告。`flutter test --coverage` 确认 `trip_stop_actions.dart` 覆盖率达到项目规范的 80%。

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-08-24 | 初始版本：两级页面重构（A）与节点内容编辑（B）设计；拖拽排序（C）明确排除 |
