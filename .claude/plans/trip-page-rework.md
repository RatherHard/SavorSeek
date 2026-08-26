# 行程页面五项整改实施计划

> 供后续 agent 按阶段执行。本文档只描述整改范围、现状、约束、实施顺序和验收标准；不要在未获得用户确认前修改代码、数据库迁移或其他文档。
>
> 生成日期：2026-08-26
> 当前分支：`dev`

## 1. 目标与范围

本轮只处理以下五项行程页面整改：

1. 移除“修改行程时区”功能，并同步调整数据库能力。
2. 将“完成行程”“取消行程”按钮从顶部菜单移动到页面底部。
3. 页面不再以“草稿”作为用户可见状态；根据当天时间显示“待出行”“进行中”或“已完成”，并评估是否需要数据库状态迁移。
4. 添加/编辑/调整节点时，继续使用“开始时间 + 停留时长”，但将固定时长选项改为卷帘式小时/分钟选择。
5. 修复创建节点后页面底部提示不会消失的问题。

### 本轮明确不做

- 不删除 `trips.timezone` 字段。
- 不删除 `planned_start_at` 或 `planned_end_at` 字段。
- 不把“待出行/进行中”这种随当前日期变化的展示状态自动写回数据库，除非用户另行确认。
- 不修改已提交的历史迁移文件；所有数据库变更必须新增前向迁移。
- 不新增重复的 `itinerary` 或 `nodes` 表。
- 不扩大到归档、Agent 自动排程、路线缓存、交通方式修复等未列入本轮的能力。

## 2. 当前系统基线

### 2.1 页面和调用链

当前实际页面不是旧的单体 `TripPage`，而是：

```text
AppShell
└── TripListPage
    └── TripDetailPage(tripId)
        ├── TripController
        ├── TripMapper
        ├── TripStopActions
        ├── TripLifecycleActions
        └── TripRepository / Supabase RPC
```

关键文件：

| 文件 | 职责 |
|---|---|
| `apps/mobile/lib/features/trip/trip_list_page.dart` | 行程列表、状态徽章、进入详情 |
| `apps/mobile/lib/features/trip/trip_detail_page.dart` | 详情页、顶部菜单、底部入口、SnackBar、动作分发 |
| `apps/mobile/lib/features/trip/trip_lifecycle_menu.dart` | 行程级菜单和完成确认弹窗 |
| `apps/mobile/lib/features/trip/trip_lifecycle_actions.dart` | 完成、取消、删除的写入编排 |
| `apps/mobile/lib/features/trip/trip_stop_actions.dart` | 节点添加、编辑、改期、删除、撤销 |
| `apps/mobile/lib/features/trip/trip_timeline.dart` | 按天时间轴、节点卡片和节点菜单 |
| `apps/mobile/lib/features/trip/add_stop_sheet.dart` | 添加普通节点/地点节点 |
| `apps/mobile/lib/features/trip/edit_stop_sheet.dart` | 编辑节点标题、备注和排期 |
| `apps/mobile/lib/features/trip/schedule_picker_sheet.dart` | 探索页将地点加入行程时的排期表单 |
| `apps/mobile/lib/features/trip/trip_models.dart` | `TripPlan`、`TripStop`、状态枚举 |
| `apps/mobile/lib/features/trip/trip_mapper.dart` | Supabase 行数据转 Flutter 模型 |
| `apps/mobile/lib/features/trip/trip_repository.dart` | Repository、Writer 和 RPC 调用 |
| `apps/mobile/lib/features/trip/trip_time_zone.dart` | IANA 时区换算 |

### 2.2 当前行程级操作

详情页 `trip_detail_page.dart` 当前在 `AppBar.actions` 中渲染 `TripLifecycleMenu`，菜单包含：

- 更改行程时区；
- 完成行程；
- 取消行程；
- 删除行程。

相关调用链：

```text
TripLifecycleMenu
├── changeTimezone
│   └── TripDetailPage._changeTimezone()
│       └── TripStopActions.changeTimezone()
│           └── TripWriter.changeTripTimezone()
│               └── RPC change_trip_timezone
├── complete
│   └── TripDetailPage._completeTrip()
│       └── TripLifecycleActions.complete()
│           └── TripWriter.completeTrip()
│               └── RPC complete_trip
├── cancel
│   └── TripDetailPage._cancelTrip()
│       └── TripLifecycleActions.cancel()
│           └── TripWriter.cancelTrip()
│               └── RPC cancel_trip
└── delete
    └── TripDetailPage._deleteTrip()
        └── TripLifecycleActions.delete()
            └── TripWriter.deleteTrip()
                └── RPC delete_trip
```

### 2.3 当前底部区域

`TripDetailPage` 的内容组件 `_TripDetail` 当前使用 `Stack`：

- 普通状态：右下角 `FloatingActionButton.extended`，文本为“添加节点”；
- 多选状态：底部 `_BatchActionBar`，用于批量删除；
- 详情内容底部通过 padding 给 FAB/操作条预留空间。

新增完成/取消操作时，必须避免与这两个底部区域以及 SnackBar 互相遮挡。

### 2.4 当前节点时间模型

数据库和 Repository 已经使用开始/结束绝对时间：

```sql
planned_start_at timestamptz not null,
planned_end_at timestamptz not null,
constraint trip_items_time_ck check (planned_end_at > planned_start_at)
```

数据库来源：

- `supabase/migrations/20260821000002_itinerary_schema.sql:53-92`
- `supabase/migrations/20260825000011_trip_page_consolidation.sql:354-365`

但 Flutter 表单和动作层仍使用：

```text
日期 + 开始时间 + 停留时长
```

相关位置：

- `add_stop_sheet.dart`：时长 ChoiceChip；
- `edit_stop_sheet.dart`：时长 ChoiceChip；
- `schedule_picker_sheet.dart`：时长 ChoiceChip；
- `trip_stop_actions.dart`：`start.add(duration)` 推导结束时刻。

因此第 4 项主要是客户端输入模型和时间转换逻辑重构，不是新增数据库字段。

### 2.5 当前 SnackBar 逻辑

动作结果链路：

```text
TripStopActions / TripLifecycleActions
└── outcomes
    └── TripDetailPage._onOutcome()
        └── _showMessage()
            └── ScaffoldMessenger.showSnackBar()
```

当前 `_showMessage()` 位于：

- `apps/mobile/lib/features/trip/trip_detail_page.dart:151-160`

节点添加成功结果位于：

- `apps/mobile/lib/features/trip/trip_stop_actions.dart:194-225`
- `apps/mobile/lib/features/trip/trip_stop_actions.dart:249-285`

整改时先复现并确认问题是：

1. 旧 SnackBar 排队，导致用户感觉提示不消失；
2. SnackBar 没有显式 duration；
3. 底部 FAB/操作条遮挡或覆盖提示；
4. 还是存在其他底部 Banner/提示组件未重置。

不要在未复现前假定一定是某一种原因。

## 3. 数据库现状与不可变约束

### 3.1 核心表

当前数据库是三表聚合：

```text
trips
├── trip_days
│   └── trip_items
└── trip_idempotency_keys
```

`trips` 关键字段：

- `timezone text not null default 'Asia/Shanghai'`
- `start_date date not null`
- `end_date date not null`
- `status text not null default 'draft'`
- `revision bigint not null default 1`
- `archived_at timestamptz`

当前状态约束：

```text
'draft', 'confirmed', 'in_progress', 'completed', 'cancelled'
```

`trip_items` 关键字段：

- `trip_day_id`
- `planned_start_at timestamptz`
- `planned_end_at timestamptz`
- `time_slot`
- `status`
- `place_snapshot`

### 3.2 写入边界

认证客户端对核心表只有读取权限，写入必须通过 `security definer` RPC：

- 所有权使用 `auth.uid()` 校验；
- 通常锁定 `trips` 聚合根；
- 使用 `expected_revision`；
- 使用幂等键；
- 成功后 `revision` 只增加一次；
- 冲突错误码使用 `P0002`。

后续不得为了页面方便开放核心表直接写入权限。

### 3.3 时区语义

`trips.timezone` 仍然是行程时间语义的基础：

- `trip_days.local_date` 是行程时区下的自然日；
- 节点 `planned_start_at`/`planned_end_at` 是绝对时刻；
- 节点按行程时区展示墙上时间；
- 节点写入时，用户选择的墙上时间必须按该时区转为 UTC；
- 数据库根据父行程时区校验节点开始日期是否属于目标 `trip_day`。

本轮“移除时区更改功能”只移除修改能力，不移除上述时区语义。

### 3.4 线上数据库状态不能假定

仓库记忆已经明确：迁移不会自动应用到数据库。实施前和部署前必须查询：

- `supabase_migrations.schema_migrations`；
- `pg_proc`；
- `information_schema.routine_privileges`；
- 表字段、约束、索引、触发器和 RLS policy。

重点确认 `20260825000011_trip_page_consolidation.sql` 是否已在线上应用。

## 4. 目标行为定义

### 4.1 时区修改功能

目标行为：

- 创建行程时仍可选择时区；
- 详情页仍按行程时区显示时间；
- 详情页不再出现“更改行程时区”；
- `TripWriter`、Repository、动作编排中不再提供修改时区 API；
- 数据库删除 `change_trip_timezone` RPC；
- 已有行程的 `timezone` 不允许被普通 UPDATE 改变；
- `validate_trip_row()` 仍校验时区必须是有效 IANA 标识。

### 4.2 行程显示状态

默认采用“持久化状态 + 时间派生展示状态”：

| 条件 | 页面展示 |
|---|---|
| 持久化状态为 `cancelled` | 已取消 |
| 持久化状态为 `completed` | 已完成 |
| 当前行程当地日期早于 `start_date` | 待出行 |
| 当前行程当地日期处于 `[start_date, end_date]` | 进行中 |
| 当前行程当地日期晚于 `end_date` | 已完成 |

当前日期必须通过：

```text
DateTime.now().toUtc()
→ trips.timezone
→ 行程当地自然日
```

不能使用设备本地日期或 UTC 日期直接判断。

默认不自动写回 `trips.status`。`complete_trip` 和 `cancel_trip` 仍然是显式用户操作。

如果用户最终要求数据库只保留“待出行/进行中”两种状态，必须另开高风险方案，重新评估状态约束和历史数据迁移，不得顺手实现。

### 4.3 底部完成/取消操作

目标行为：

- 从 AppBar 菜单中移除完成、取消；
- 在详情页内容底部增加生命周期操作区；
- 非 `completed`、非 `cancelled` 行程显示完成和取消；
- `completed`、`cancelled` 行程不显示这两个按钮；
- 完成操作保留确认弹窗；
- 取消操作增加确认弹窗，避免误触；
- 提交期间禁用按钮或显示忙碌状态；
- 仍沿用 `TripLifecycleActions` 的 reload、冲突处理和错误提示。

底部区域必须与以下组件协调：

- 添加节点 FAB；
- 多选批量操作条；
- SnackBar；
- 系统 SafeArea 和底部手势区域。

### 4.4 节点时间

目标输入：

```text
日期 + 开始时间 + 时长
```

本轮不改为“开始时间 + 结束时间”。用户继续选择开始时间和停留时长，但停留时长不再使用固定 ChoiceChip；改为卷帘式的小时、分钟选择器，允许更精确地表达停留时长。

涉及：

- 添加普通节点；
- 添加地点节点；
- 编辑节点；
- 探索页将地点加入行程；
- 改期；
- 撤销。

`time_slot` 继续由开始时间推导，不单独让用户编辑。

数据库继续接收：

```text
planned_start_at
planned_end_at
```

客户端仍以 `planned_start_at + duration` 构造 `planned_end_at`，但 duration 必须来自统一的卷帘选择结果，不得在多个动作层重复实现时长默认值或解析逻辑。

停留时长策略：

- 默认开始时间保持 `12:00`；
- 默认停留时长保持 1 小时；
- 小时与分钟分别通过卷帘式选择器选择；
- 时长必须大于 0；
- 分钟建议按 5 分钟步进，小时和分钟上限应由统一常量控制；
- 跨午夜继续支持：结束 instant 由开始 instant 加 duration 得出，数据库 `planned_end_at > planned_start_at` 约束继续成立；
- UI 预览明确显示结束时间，并在跨午夜时标注“次日”；
- 不允许用户直接编辑结束时间，因此不引入 `endsNextDay` 或新的结束时间字段。

客户端仍需保证：

- 不把设备本地 `DateTime` 当作行程时间直接传输；
- 所有写入均由行程时区的开始墙上时间转换为 instant，再加 duration；
- 撤销快照保存原始 `planned_start_at`、`planned_end_at`、所属行程日和原时段。

### 4.5 创建节点后的底部提示

目标行为：

- 节点创建成功后显示提示；
- 提示在明确 duration 后自动消失；
- 新提示到达时不无限排队旧提示；
- 失败提示也能自动消失；
- 撤销按钮继续可用；
- 页面离开后不残留旧提示。

建议优先考虑：

```text
显示新 SnackBar 前关闭 current SnackBar
设置明确 duration
根据底部操作条配置底部 inset
```

最终方案以复现结果为准。

## 5. 推荐实施阶段

## Phase 0：确认环境和需求边界

### 任务

1. 对账线上迁移版本和关键数据库对象。
2. 查询线上 `trips.status` 的实际分布。
3. 查询是否有非默认时区、跨午夜节点和异常状态。
4. 复现底部提示不消失问题。
5. 确认“已结束”是否作为展示状态。
6. 确认跨午夜节点是否继续支持。
7. 确认取消行程是否需要确认弹窗。

### 产出

- 不修改仓库；
- 记录线上对账结果；
- 明确未决产品选项后再进入实现。

## Phase 1：移除时区修改能力

### Flutter 文件

修改：

- `apps/mobile/lib/features/trip/trip_lifecycle_menu.dart`
- `apps/mobile/lib/features/trip/trip_detail_page.dart`
- `apps/mobile/lib/features/trip/trip_stop_actions.dart`
- `apps/mobile/lib/features/trip/trip_repository.dart`
- `apps/mobile/lib/features/trip/trip_repository_fakes.dart`

动作：

1. 移除 `TripAction.changeTimezone` 及其菜单项。
2. 删除 `TripDetailPage._changeTimezone()`。
3. 删除 `TripStopActions.changeTimezone()`。
4. 从 `TripWriter` 删除 `changeTripTimezone()`。
5. 从 `SupabaseTripRepository` 删除对应 RPC 调用。
6. 清理无用 import、Fake 实现和测试。
7. 保留 `create_trip_sheet.dart` 的创建时区选择。
8. 保留 `TripPlan.timezone`、`TripTimeZone` 和详情页时区说明。

### 数据库迁移

新增一个晚于 `20260825000011` 的迁移，例如：

```text
supabase/migrations/20260826000012_remove_trip_timezone_mutation.sql
```

迁移要求：

1. `drop function if exists public.change_trip_timezone(uuid, bigint, uuid, text);`
2. 重新定义 `validate_trip_row()`，删除 `savorseek.timezone_migration` 放行逻辑。
3. 保留有效 IANA 时区校验。
4. 保留 revision、日期范围、预算和状态校验。
5. 清理旧 RPC 的 revoke/grant 语句。
6. 不修改历史迁移文件。

需要明确验证普通 UPDATE 是否会被拒绝。如果当前 trigger 没有单独阻止 timezone 变化，必须补充一致的数据库保护，而不能只删除 RPC。

### 验证

- 详情页没有时区修改入口；
- 创建时仍能选择时区；
- 已有东京/纽约等非默认时区行程能正常读取；
- 节点添加、编辑、改期仍按行程时区转换；
- `change_trip_timezone` 不存在；
- 直接变更已有行程 timezone 被数据库拒绝。

## Phase 2：统一节点开始/结束时间

### 影响文件

- `apps/mobile/lib/features/trip/schedule_picker_sheet.dart`
- `apps/mobile/lib/features/trip/add_stop_sheet.dart`
- `apps/mobile/lib/features/trip/edit_stop_sheet.dart`
- `apps/mobile/lib/features/trip/trip_detail_page.dart`
- `apps/mobile/lib/features/trip/trip_stop_actions.dart`
- `apps/mobile/lib/features/trip/add_place_to_trip.dart`
- `apps/mobile/lib/features/trip/trip_repository.dart`（如接口命名需要同步）

### 数据模型改造

将 `ScheduleSelection` 保持为“行程日 + 开始墙上时间 + 停留时长”，但将停留时长的输入控件从固定 ChoiceChip 改为卷帘式小时/分钟选择器，例如：

```dart
class ScheduleSelection {
  const ScheduleSelection({
    required this.day,
    required this.startTime,
    required this.duration,
  });

  final TripDayRef day;
  final TimeOfDay startTime;
  final Duration duration;
}
```

具体类型可按现有代码风格调整，但必须满足：

- 开始时间和时长都有明确值；
- 小时/分钟卷帘选择结果统一转换为 `Duration`；
- 时长大于 0，并受统一的最小/最大值约束；
- 结束墙上时间只作为预览值，不作为第二个用户输入字段；
- 跨午夜由 `start + duration` 的 instant 结果明确呈现“次日”，不靠结束时间倒推语义；
- 不把设备本地 `DateTime` 当作行程时间直接传输。

### 表单改造

1. 保留开始时间选择器；
2. 删除固定停留时长 ChoiceChip；
3. 增加卷帘式小时、分钟选择器；
4. 默认值改为开始 `12:00`、停留 `1 小时 0 分钟`；
5. 编辑时从 `startAt` 和 `endAt` 计算初始 duration，并分别填入小时/分钟卷帘；
6. 显示 `19:00–20:30` 形式的区间；
7. 跨午夜显示 `23:00–次日 01:00`；
8. 保存前本地校验 duration 大于 0 且不超过上限；
9. `time_slot` 继续依据开始小时推导。

### 动作层改造

`TripStopActions` 中：

- 继续接收 `duration`，但移除动作层自行决定默认时长或解析用户输入的责任；
- 表单先将卷帘结果规范化为统一 `Duration`，动作层只负责时区转换和写入；
- 通过 `TripTimeZone.toInstant()` 转换开始墙上时间；
- 使用明确的 `start + duration` 构造结束 instant，不在多个调用点复制转换逻辑；
- 撤销快照保存原始 `planned_start_at`、`planned_end_at`、所属行程日和原时段；
- 为跨午夜、夏令时和撤销增加纯逻辑测试，确保 duration 计算不会丢失真实结束 instant。

### 数据库

默认不新增或删除字段。继续使用：

```text
planned_start_at timestamptz
planned_end_at timestamptz
```

现有 `planned_end_at > planned_start_at` 约束继续保留。跨午夜时由开始 instant 加 duration 构造结束 instant，数据库比较仍然成立。

### 验证

- 添加普通节点使用开始时间 + 卷帘时长；
- 添加地点节点使用开始时间 + 卷帘时长；
- 编辑节点正确预填开始时间和小时/分钟时长；
- 探索页加入行程流程正常；
- 改期正常；
- 撤销恢复原始起止时间；
- 卷帘选择 0 分钟时阻止提交；
- 跨时区和跨午夜测试通过；
- RPC payload 中包含开始和结束两个时间，结束时间由统一 duration helper 计算。

## Phase 3：行程状态展示

### 新增纯逻辑模块

建议新增：

```text
apps/mobile/lib/features/trip/trip_temporal_status.dart
```

职责：

- 接收 `TripPlan` 或日期范围、时区、当前 instant；
- 返回展示状态；
- 不读取 `DateTime.now()`；
- 不进行数据库写入；
- 不依赖 Widget。

建议定义：

```dart
enum TripDisplayStatus {
  upcoming,
  inProgress,
  ended,
  completed,
  cancelled,
}
```

持久化状态优先级高于日期派生状态：

```text
cancelled > completed > 日期派生
```

日期派生规则为：

```text
当前行程当地日期早于 start_date  → upcoming（待出行）
当前行程当地日期处于 [start_date, end_date] → inProgress（进行中）
当前行程当地日期晚于 end_date → completed（已完成，仅展示，不自动写库）
```

这里的 `completed` 在日期已过的场景是展示状态，不等同于持久化 `trips.status = 'completed'`；生命周期按钮是否显示仍依据持久化状态。

### 页面接入

修改：

- `apps/mobile/lib/features/trip/trip_list_page.dart`
- `apps/mobile/lib/features/trip/trip_detail_page.dart`
- 必要时新增共享状态徽章组件

将“草稿”用户文案替换为“待出行”，并确保列表与详情使用同一 resolver，不能各自实现日期判断。日期晚于 `end_date` 时显示“已完成”；该展示值不得写回数据库。

### 刷新策略

优先采用低复杂度方案：

- 初次加载时计算；
- 页面回到前台或重新加载时计算；
- 如确实要求停留页面中自动更新，再增加页面级定时器；
- 定时器只刷新派生状态，不写数据库；
- 页面销毁时取消定时器。

### 验证

覆盖：

- 上海、东京、纽约等时区；
- 行程当地日期早于、等于、处于、晚于日期范围；
- completed/cancelled 优先；
- 设备时区变化不影响结果；
- 不会调用状态写入 RPC。

## Phase 4：完成/取消移动到底部

### 页面结构

修改：

- `apps/mobile/lib/features/trip/trip_detail_page.dart`
- `apps/mobile/lib/features/trip/trip_lifecycle_menu.dart`

新增或拆分：

```text
_TripLifecycleActionBar
```

建议布局：

```text
底部生命周期操作区：
[完成行程] [取消行程]
```

与现有底部组件的优先级：

```text
多选态：只显示 _BatchActionBar
普通可编辑态：显示生命周期操作区 + 添加节点入口
completed/cancelled：不显示完成/取消操作区
```

如底部高度过大，应将 FAB 变成位于生命周期操作区上方的按钮，或把普通操作合并为统一底部操作区；最终选择以小屏 Widget 测试结果为准。

### 动作行为

- 完成：继续 `confirmCompleteTrip()`；
- 取消：增加 `confirmCancelTrip()`；
- 成功后继续 reload；
- 冲突继续 reload；
- busy 时禁用重复提交；
- 失败使用现有 outcome/SnackBar 机制。

### 验证

- AppBar 不显示完成/取消；
- 底部显示完成/取消；
- completed/cancelled 不显示；
- 点击完成/取消触发正确 RPC；
- 确认、取消、失败、冲突和 busy 分支覆盖；
- 320/375 宽度下无溢出、遮挡或不可点击区域。

## Phase 5：修复底部提示生命周期

### 首选检查点

修改前先使用现有测试或手动运行复现：

1. 创建普通节点；
2. 创建地点节点；
3. 连续快速创建多个节点；
4. 创建失败；
5. 点击撤销；
6. 在提示显示期间触发完成/取消或打开表单；
7. 返回上一页。

### 可能的实现方式

在 `_showMessage()` 中：

- 每次显示前 `hideCurrentSnackBar()` 或 `removeCurrentSnackBar()`；
- 设置明确的 `duration`；
- 根据成功/失败设置合理时长；
- 保留撤销 `SnackBarAction`；
- 计算 `behavior`/`margin`，避免底部操作条遮挡；
- 页面未 mounted 时不显示。

如果复现结果表明残留的是其他底部提示组件，则只修复真实根因，不增加重复的提示系统。

### 验证

- 创建成功提示出现；
- duration 后自动消失；
- 新提示替换旧提示而不是无限排队；
- 创建失败提示自动消失；
- 撤销仍然可用；
- 页面退出后无残留；
- 与底部生命周期操作区不冲突。

## 6. 测试计划

### 6.1 单元测试

新增或更新：

- `apps/mobile/test/trip/trip_temporal_status_test.dart`
- `apps/mobile/test/trip/trip_time_zone_test.dart`
- `apps/mobile/test/trip/trip_mapper_timezone_test.dart`
- `apps/mobile/test/trip/trip_item_lifecycle_test.dart`
- `apps/mobile/test/trip/trip_undo_test.dart`
- `apps/mobile/test/trip/trip_reschedule_test.dart`

必须覆盖：

- 展示状态的日期边界；
- 时区转换；
- 夏令时；
- 跨午夜；
- 起止时间转换；
- 撤销保存和恢复原始起止时间；
- 取消/完成动作的 revision 和错误分支。

### 6.2 表单测试

更新：

- `apps/mobile/test/trip/add_place_to_trip_test.dart`
- `apps/mobile/test/trip/schedule_picker_sheet_test.dart`
- `apps/mobile/test/trip/trip_entry_points_test.dart`
- `apps/mobile/test/trip/trip_detail_page_test.dart`

删除或改写所有依赖“停留时长 ChoiceChip”的断言，新增：

- 开始时间和结束时间默认值；
- 结束时间编辑；
- 起止时间校验；
- 跨午夜提示；
- 节点添加后成功提示自动消失。

### 6.3 页面 Widget 测试

必须覆盖：

1. 详情页顶部菜单不再有时区修改；
2. 详情页顶部菜单不再有完成/取消；
3. 底部显示完成/取消；
4. completed/cancelled 状态下隐藏底部生命周期操作；
5. 添加节点按钮和底部操作区不重叠；
6. 多选态只显示批量操作条；
7. 320、375 宽度无布局溢出；
8. 节点创建成功后提示出现并按 duration 消失；
9. 只读仓库不显示写入入口；
10. 非默认时区行程仍正常展示。

### 6.4 数据库验证

更新或新增 SQL 核对脚本，至少检查：

```sql
-- change_trip_timezone 不存在
-- trips.timezone 仍存在
-- trip_items.planned_start_at / planned_end_at 仍存在
-- timezone 不可通过普通更新改变
-- complete_trip / cancel_trip 仍存在
-- edit_trip_item 仍使用两个 timestamptz
-- authenticated 仍无核心表直接写权限
```

现有核对脚本：

- `supabase/snippets/verify_trip_page_consolidation.sql`

如新增迁移影响现有核对条件，应同步扩展该脚本，但不要删除原有有效检查。

## 7. 迁移与部署顺序

### 7.1 仓库内迁移顺序

已有相关迁移：

```text
20260821000002_itinerary_schema.sql
20260821000003_itinerary_rpcs.sql
20260824000007_reschedule_trip_item.sql
20260824000008_timezone_and_item_lifecycle.sql
20260824000009_batch_trip_item_ops.sql
20260824000010_update_trip_item.sql
20260825000011_trip_page_consolidation.sql
```

新迁移必须使用更晚的 14 位版本号，例如：

```text
20260826000012_remove_trip_timezone_mutation.sql
```

不要编辑历史迁移。

### 7.2 上线前对账

先确认：

1. 远端已应用到哪个迁移版本；
2. 旧 RPC 是否存在；
3. 新旧函数签名是否一致；
4. execute 权限是否只授予 `authenticated`；
5. RLS 和核心表直接写权限是否正确；
6. 线上数据是否包含需兼容的跨午夜节点或非默认时区。

### 7.3 推荐执行顺序

```text
1. 复现底部提示问题
2. 确认未决产品选项
3. 新增/更新测试，先得到失败用例
4. 实现 Phase 1：移除时区修改
5. 应用并核对数据库迁移
6. 实现 Phase 2：起止时间输入
7. 实现 Phase 3：时间派生状态
8. 实现 Phase 4：底部完成/取消
9. 实现 Phase 5：提示生命周期修复
10. flutter analyze
11. flutter test
12. flutter test --coverage
13. 真实 Supabase RPC 验证
14. Android 模拟器/真机页面验证
15. 按项目规则更新开发日志和架构文档
```

## 8. 风险与处理方式

| 风险 | 等级 | 处理方式 |
|---|---|---|
| 误删 `trips.timezone` 导致时间语义失效 | 高 | 只删除修改入口和 RPC，保留字段及换算逻辑 |
| 线上迁移版本落后于仓库 | 高 | 先查 `schema_migrations`、`pg_proc`、权限和 RLS |
| 动态展示状态被错误写回数据库 | 高 | 使用纯逻辑 resolver，显式状态仍由用户操作 |
| 设备时区被误用于行程日期判断 | 高 | 所有判断以 UTC instant + 行程 IANA 时区为准 |
| 跨午夜编辑破坏历史数据 | 高 | 明确次日语义；实现前查询历史数据；补边界测试 |
| 完成/取消与 FAB、批量条、SnackBar 重叠 | 中 | 统一底部布局，补窄屏 Widget 测试 |
| 旧测试仍假定 duration 输入 | 中 | 按调用链更新所有表单、动作和撤销测试 |
| SnackBar 实际问题不是 duration | 中 | 先复现；只修复确认的真实根因 |
| `cancelled` 与 `completed` 的可编辑语义混淆 | 中 | 沿用当前数据库语义：completed 只读，cancelled 仍可整理；不要扩大本轮范围 |
| 直接普通 UPDATE 仍能修改 timezone | 高 | 删除 RPC 后必须验证 trigger/约束仍阻止裸修改 |

## 9. 验收标准

### 时区

- [ ] 详情页不再显示修改行程时区入口。
- [ ] `change_trip_timezone` RPC 已删除。
- [ ] `trips.timezone` 字段仍存在。
- [ ] 创建行程时仍可选择时区。
- [ ] 已有非默认时区行程可正常读取、展示和编辑节点。
- [ ] 已有行程不能通过普通更新改变时区。

### 行程状态

- [ ] 用户界面不再显示“草稿”作为主要状态文案。
- [ ] 开始日期前显示“待出行”。
- [ ] 行程日期区间内显示“进行中”。
- [ ] completed/cancelled 优先显示其持久化状态。
- [ ] 日期变化不会自动调用状态写入 RPC。
- [ ] 判断使用行程时区，而不是设备时区或 UTC 日期。

### 底部完成/取消

- [ ] AppBar 菜单不再显示完成行程。
- [ ] AppBar 菜单不再显示取消行程。
- [ ] 页面底部显示完成和取消按钮。
- [ ] 完成和取消有确认、busy、失败和冲突处理。
- [ ] completed/cancelled 状态下隐藏按钮。
- [ ] 小屏无溢出，节点和底部提示不被遮挡。

### 节点时间

- [ ] 添加节点使用开始时间 + 结束时间。
- [ ] 编辑节点使用开始时间 + 结束时间。
- [ ] 探索页加入行程流程同步使用新模型。
- [ ] 数据库仍使用 `planned_start_at` 和 `planned_end_at`。
- [ ] 不再使用 duration 推导结束时间。
- [ ] 起止时间校验在客户端和数据库端均有效。
- [ ] 跨午夜策略明确且有测试。
- [ ] 撤销能恢复原始起止时间。

### 底部提示

- [ ] 创建节点成功后提示会出现。
- [ ] 提示在明确 duration 后自动消失。
- [ ] 连续操作不会无限排队旧提示。
- [ ] 失败提示也会自动消失。
- [ ] 撤销按钮仍可用。
- [ ] 页面离开后没有残留提示。

### 工程验证

```bash
cd apps/mobile
flutter analyze
flutter test
flutter test --coverage
```

并执行：

```bash
node .github/scripts/check-migration-names.mjs
```

在真实 Supabase 实例执行迁移核对脚本和关键 RPC 成功/失败/冲突测试。

## 10. Agent 执行纪律

1. 开工前先读取本计划和相关现有文件，不要凭旧 worktree 文件推断当前实现。
2. 先写或更新失败测试，再实现行为；避免只改断言让测试“通过”。
3. 迁移只新增，不修改历史迁移。
4. 所有数据库写入继续走受控 RPC，不开放核心表 DML。
5. 时间判断和时间转换必须注入 `now`，避免单测依赖真实系统时间。
6. 不得把展示状态自动写回数据库。
7. 不得删除 `trips.timezone`、`planned_start_at`、`planned_end_at`。
8. 完成每个 Phase 后运行相关测试和 `flutter analyze`。
9. 修改 Dart 后运行 `dart format`。
10. 代码完成后必须使用 `code-reviewer`，涉及数据库迁移时同时使用 `database-reviewer`；若修改安全边界，再使用 `security-reviewer`。
11. 未经用户明确要求，不要 commit、push 或修改其他文档。
