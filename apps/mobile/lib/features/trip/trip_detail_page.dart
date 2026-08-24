import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';
import 'package:savorseek/features/explore/amap_consent.dart';

import 'add_stop_sheet.dart';
import 'edit_stop_sheet.dart';
import 'schedule_picker_sheet.dart';
import 'timezone_picker_sheet.dart';
import 'trip_controller.dart';
import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_route_map.dart';
import 'trip_route_page.dart';
import 'trip_route_service.dart';
import 'trip_status_views.dart';
import 'trip_stop_actions.dart';
import 'trip_time_zone.dart';
import 'trip_timeline.dart';

/// 行程级操作，作用于整个行程而非单个项。
///
/// 不含「新建行程」：那是列表层面的操作，已移到一级页面。
enum TripAction { changeTimezone }

/// 行程二级页面：查看与编辑单个行程的节点。
///
/// 自带 Scaffold 与 AppBar：本页由根 Navigator push，盖住 AppShell 的顶部主导航，
/// 因此返回键与标题都要自己提供。代价是在本页内无法直接切到探索/我的，需先返回
/// ——这与两级结构的语义一致：进去做事、做完返回。
class TripDetailPage extends StatefulWidget {
  const TripDetailPage({
    super.key,
    required this.repository,
    required this.tripId,
    this.auth,
    this.mapConsent,
    this.routeService,
  });

  final TripRepository repository;

  /// 要查看的行程 id。由列表页传入。
  final String tripId;

  /// 认证服务。为空时不提供登录入口，仅展示错误原因。
  final AuthService? auth;

  /// 高德合规同意状态。为空时不显示路线地图（Widget 测试无法初始化地图 SDK）。
  final AmapConsent? mapConsent;

  /// 真实路网路线来源。为空时地图退化为直线连接。
  final TripRouteService? routeService;

  @override
  State<TripDetailPage> createState() => _TripDetailPageState();
}

class _TripDetailPageState extends State<TripDetailPage> {
  late final TripController _controller = TripController(
    widget.repository,
    tripId: widget.tripId,
  );

  /// 写入编排。仅在仓库具备写入能力时创建。
  TripStopActions? _actions;
  StreamSubscription<TripActionOutcome>? _outcomeSubscription;
  StreamSubscription<String?>? _authSubscription;

  /// 已选中的行程项 id。非空即处于多选态。
  ///
  /// 只存 id 而非 TripStop：每次重载都会得到新的对象，存实例会在重载后失配。
  final Set<String> _selectedStopIds = {};

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onStateChanged);

    final repository = widget.repository;
    if (repository is TripWriter) {
      final actions = TripStopActions(
        // 显式转换而非依赖类型提升：promotion 不跨越 TripStopActions 内部持有的
        // 闭包边界保留，写成 as 更直白也更稳定。
        writer: repository as TripWriter,
        reload: _controller.load,
      );
      // 结果统一在此变成提示条：SnackBar 需要 context，而编排层刻意不持有它。
      _outcomeSubscription = actions.outcomes.listen(_onOutcome);
      actions.isBusy.addListener(_onStateChanged);
      _actions = actions;
    }

    // 行程数据是用户私有的，登出后仍留在屏幕上不合适。详情页与列表页都订阅：
    // 只让列表页订阅会留下一个「详情页显示已登出用户数据」的窗口。
    _authSubscription = widget.auth?.userIdChanges.listen((_) {
      _controller.load();
    });
    _controller.load();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _outcomeSubscription?.cancel();
    _actions?.isBusy.removeListener(_onStateChanged);
    _actions?.dispose();
    _controller
      ..removeListener(_onStateChanged)
      ..dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _onOutcome(TripActionOutcome outcome) {
    if (!mounted) return;
    switch (outcome) {
      case TripActionSucceeded(:final message, :final undo):
        _showMessage(message, undo: undo);
      case TripActionFailed(:final message):
        _showMessage(message);
    }
  }

  void _showMessage(String message, {TripUndo? undo}) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        // 误操作后的第一反应是「撤销」，而不是回列表里找刚才那一项再选恢复。
        action: undo == null
            ? null
            : SnackBarAction(label: '撤销', onPressed: () => _runUndo(undo)),
      ),
    );
  }

  /// 撤销必须用「撤销时」的最新 revision，而不是被撤销那次操作所用的旧值。
  void _runUndo(TripUndo undo) {
    final state = _controller.state;
    if (state is! TripLoaded) return;
    _actions?.undo(undo, currentRevision: state.plan.revision);
  }

  Future<void> _signIn() async {
    final auth = widget.auth;
    if (auth == null) return;
    final didSignIn = await showAuthSheet(context, auth: auth);
    if (didSignIn && mounted) await _controller.load();
  }

  void _toggleSelection(TripStop stop) {
    setState(() {
      if (!_selectedStopIds.remove(stop.id)) _selectedStopIds.add(stop.id);
    });
  }

  void _clearSelection() {
    if (_selectedStopIds.isEmpty) return;
    setState(_selectedStopIds.clear);
  }

  /// 分派行程项操作。
  Future<void> _handleStopAction(
    TripPlan plan,
    TripDay day,
    TripStop stop,
    StopAction action,
  ) async {
    final actions = _actions;
    if (actions == null) return;
    switch (action) {
      case StopAction.reschedule:
        await _reschedule(actions, plan, day, stop);
      case StopAction.edit:
        await _edit(actions, plan, stop);
      case StopAction.cancel:
        await actions.cancel(plan: plan, stop: stop);
      case StopAction.restore:
        await actions.restore(plan: plan, stop: stop);
      case StopAction.delete:
        // 硬删除不可恢复，必须二次确认。取消同样能让项从计划中消失，
        // 且可反悔，因此确认框里把这条区别讲清楚。
        final confirmed = await _confirmDelete(stop);
        if (!confirmed || !mounted) return;
        await actions.delete(plan: plan, stop: stop);
    }
  }

  /// 改期。
  ///
  /// [TripStop.startAt] 已是行程时区下的墙上时间（见 TripMapper），可直接作为
  /// 选择器初值，无需再做时区换算——若此处再折算一次就会双重偏移。
  Future<void> _reschedule(
    TripStopActions actions,
    TripPlan plan,
    TripDay day,
    TripStop stop,
  ) async {
    final dayId = day.id ?? stop.tripDayId;
    if (dayId == null) return;

    // 行程的全部日期都可作为目标，跨天移动由服务端重算 position。
    final days = plan.days
        .where((item) => item.id != null)
        .map((item) => TripDayRef(id: item.id!, localDate: item.date))
        .toList(growable: false);
    if (days.isEmpty) return;

    final current = days.firstWhere(
      (item) => item.id == dayId,
      orElse: () => days.first,
    );
    final selection = await showSchedulePickerSheet(
      context,
      placeName: stop.title,
      trip: TripSchedulingContext(
        tripId: plan.id,
        revision: plan.revision,
        timezone: plan.timezone,
        days: days,
      ),
      isReschedule: true,
      initial: ScheduleSelection(
        day: current,
        hour: stop.startAt.hour,
        minute: stop.startAt.minute,
        duration: stop.endAt.difference(stop.startAt),
      ),
    );
    if (selection == null || !mounted) return;

    await actions.reschedule(
      plan: plan,
      stop: stop,
      currentDayId: dayId,
      currentDayDate: current.localDate,
      targetDayId: selection.day.id,
      targetDayDate: selection.day.localDate,
      hour: selection.hour,
      minute: selection.minute,
      duration: selection.duration,
      timeSlot: selection.timeSlot,
    );
  }

  /// 编辑节点的标题与备注。
  Future<void> _edit(
    TripStopActions actions,
    TripPlan plan,
    TripStop stop,
  ) async {
    final draft = await showEditStopSheet(context, stop: stop);
    if (draft == null || !mounted) return;
    await actions.updateItem(
      plan: plan,
      stop: stop,
      title: draft.title,
      notes: draft.notes,
    );
  }

  Future<bool> _confirmDelete(TripStop stop) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个行程项？'),
        content: Text(
          '「${stop.title}」将被彻底删除，无法恢复。\n'
          '若只是暂时不想去，改用「取消」可以保留记录并随时恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 批量取消或删除已选项。
  Future<void> _runBatch(TripPlan plan, {required bool isDelete}) async {
    final actions = _actions;
    if (actions == null) return;
    final ids = _selectedStopIds.toList(growable: false);
    if (ids.isEmpty) return;

    if (isDelete) {
      final confirmed = await _confirmBatchDelete(ids.length);
      if (!confirmed || !mounted) return;
      await actions.batchDelete(plan: plan, stopIds: ids);
    } else {
      await actions.batchCancel(plan: plan, stopIds: ids);
    }
    _clearSelection();
  }

  Future<bool> _confirmBatchDelete(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除这 $count 个行程项？'),
        content: const Text(
          '所选行程项将被彻底删除，无法恢复。\n'
          '若只是暂时不想去，改用「取消」可以保留记录并随时恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 添加一个自由安排节点。
  Future<void> _addStop(TripPlan plan) async {
    final actions = _actions;
    if (actions == null) return;

    final days = plan.days
        .where((item) => item.id != null)
        .map((item) => TripDayRef(id: item.id!, localDate: item.date))
        .toList(growable: false);
    if (days.isEmpty) {
      _showMessage('行程还没有可安排的日期。');
      return;
    }

    final draft = await showAddStopSheet(
      context,
      trip: TripSchedulingContext(
        tripId: plan.id,
        revision: plan.revision,
        timezone: plan.timezone,
        days: days,
      ),
    );
    if (draft == null || !mounted) return;

    await actions.addBreak(
      plan: plan,
      tripDayId: draft.selection.day.id,
      dayDate: draft.selection.day.localDate,
      title: draft.title,
      hour: draft.selection.hour,
      minute: draft.selection.minute,
      duration: draft.selection.duration,
      timeSlot: draft.selection.timeSlot,
      notes: draft.note,
    );
  }

  /// 更改行程时区。
  ///
  /// 已排入的项保留当地钟点（19:00 仍是 19:00），UTC 时刻由服务端重算。这是唯一
  /// 能让项继续归属原 trip_day 的语义——保留绝对时刻会让当地日期跳到相邻一天。
  Future<void> _changeTimezone(TripPlan plan) async {
    final actions = _actions;
    if (actions == null) return;
    final picked = await showTimezonePickerSheet(
      context,
      current: plan.timezone,
    );
    if (picked == null || picked == plan.timezone || !mounted) return;
    await actions.changeTimezone(plan: plan, timezone: picked);
  }

  /// 打开全屏路线视图。
  ///
  /// 小地图关闭了手势（否则与页面滚动争夺同一个纵向拖拽），因此缩放与平移
  /// 只在全屏视图里提供。
  Future<void> _openRoute(TripPlan plan) async {
    final consent = widget.mapConsent;
    if (consent == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TripRoutePage(
          plan: plan,
          consent: consent,
          routeService: widget.routeService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      appBar: AppBar(
        // 标题取自已载入的行程；未载入时不猜，显示通用文案比显示错的好。
        title: Text(state is TripLoaded ? state.plan.title : '行程'),
        actions: [
          if (state is TripLoaded && _actions != null)
            PopupMenuButton<TripAction>(
              tooltip: '行程操作',
              icon: const Icon(Icons.more_horiz),
              onSelected: (action) => switch (action) {
                TripAction.changeTimezone => _changeTimezone(state.plan),
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: TripAction.changeTimezone,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.public),
                    title: Text('更改行程时区'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: AppTokens.durationNormal,
          child: switch (state) {
            TripLoading() => const _TripLoading(key: ValueKey('loading')),
            // 不自动 pop：无预警地弹回列表，用户不知道刚才发生了什么。
            TripDetailGone() => TripDetailGoneView(
              key: const ValueKey('gone'),
              onBack: () => Navigator.of(context).maybePop(),
            ),
            TripError(
              kind: TripRepositoryErrorKind.unauthenticated,
              :final message,
            ) =>
              TripSignInPromptView(
                key: const ValueKey('signIn'),
                message: message,
                onSignIn: widget.auth == null ? null : _signIn,
              ),
            TripError(:final message) => TripErrorView(
              key: const ValueKey('error'),
              message: message,
              onRetry: _controller.load,
            ),
            TripLoaded(:final plan) => _TripDetail(
              key: const ValueKey('loaded'),
              plan: plan,
              onStopAction: _actions == null
                  ? null
                  : (day, stop, action) =>
                        _handleStopAction(plan, day, stop, action),
              onAddStop: _actions == null ? null : () => _addStop(plan),
              mapConsent: widget.mapConsent,
              routeService: widget.routeService,
              onOpenRoute: widget.mapConsent == null
                  ? null
                  : () => _openRoute(plan),
              selectedStopIds: _selectedStopIds,
              onToggleSelection: _actions == null ? null : _toggleSelection,
              onClearSelection: _clearSelection,
              onBatchCancel: () => _runBatch(plan, isDelete: false),
              onBatchDelete: () => _runBatch(plan, isDelete: true),
            ),
          },
        ),
      ),
    );
  }
}

/// 已载入的行程内容：页头 + 小地图 + 按天时间轴。
class _TripDetail extends StatelessWidget {
  const _TripDetail({
    super.key,
    required this.plan,
    this.onStopAction,
    this.onAddStop,
    this.mapConsent,
    this.routeService,
    this.onOpenRoute,
    this.selectedStopIds = const {},
    this.onToggleSelection,
    this.onClearSelection,
    this.onBatchCancel,
    this.onBatchDelete,
  });

  final TripPlan plan;

  /// 行程项操作回调。为空时不给出操作入口。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

  /// 添加行程节点。为空时不给出入口。
  final VoidCallback? onAddStop;

  final AmapConsent? mapConsent;
  final TripRouteService? routeService;

  /// 打开全屏路线视图。为空时小地图不可点。
  final VoidCallback? onOpenRoute;

  final Set<String> selectedStopIds;
  final ValueChanged<TripStop>? onToggleSelection;
  final VoidCallback? onClearSelection;
  final VoidCallback? onBatchCancel;
  final VoidCallback? onBatchDelete;

  bool get _isSelecting => selectedStopIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scroll = _buildScrollView(context);
    if (onAddStop == null && !_isSelecting) {
      return KeyedSubtree(key: key, child: scroll);
    }
    return Stack(
      key: key,
      children: [
        Positioned.fill(child: scroll),
        // 多选态下换成批量操作条：此时「添加节点」不是用户想做的事，
        // 两个按钮并存只会互相干扰。
        if (_isSelecting)
          Positioned(
            left: AppTokens.spaceMd,
            right: AppTokens.spaceMd,
            bottom: AppTokens.spaceMd,
            child: _BatchActionBar(
              count: selectedStopIds.length,
              onCancelSelected: onBatchCancel,
              onDeleteSelected: onBatchDelete,
              onExit: onClearSelection,
            ),
          )
        else if (onAddStop != null)
          Positioned(
            right: AppTokens.spaceMd,
            bottom: AppTokens.spaceMd,
            child: FloatingActionButton.extended(
              onPressed: onAddStop,
              icon: const Icon(Icons.add),
              label: const Text('添加节点'),
            ),
          ),
      ],
    );
  }

  Widget _buildScrollView(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceMd,
            AppTokens.spaceMd,
            AppTokens.spaceSm,
          ),
          sliver: SliverToBoxAdapter(child: _TripHeader(plan: plan)),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
          sliver: SliverToBoxAdapter(
            // 有两个以上可定位节点才画路线；否则说明为何没有地图，
            // 而不是显示一张只有一个点的图。
            child: plan.hasRoute && mapConsent != null
                ? TripRouteMap(
                    plan: plan,
                    consent: mapConsent!,
                    routeService: routeService,
                    onTap: onOpenRoute,
                  )
                : TripMapFallback(state: plan.mapState),
          ),
        ),
        SliverPadding(
          // 底部留出浮动按钮的高度，否则最后一张卡片会被按钮压住无法操作。
          padding: EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceLg,
            AppTokens.spaceMd,
            onAddStop == null ? AppTokens.spaceXl : 88,
          ),
          sliver: SliverList.builder(
            itemCount: plan.days.length,
            itemBuilder: (context, index) => TripDayTimeline(
              day: plan.days[index],
              onStopAction: onStopAction,
              selectedStopIds: selectedStopIds,
              onToggleSelection: onToggleSelection,
              isSelecting: _isSelecting,
            ),
          ),
        ),
      ],
    );
  }
}

class _TripHeader extends StatelessWidget {
  const _TripHeader({required this.plan});

  final TripPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          plan.destination,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        // 仅在与设备有时差时标注时区：同时区行程标出来是冗余噪声，
        // 而跨时区时用户必须知道表上的钟点是哪儿的时间。
        if (_timezoneNotice(plan) case final notice?) ...[
          const SizedBox(height: AppTokens.spaceSm),
          Row(
            children: [
              Icon(Icons.public, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppTokens.spaceXs),
              Expanded(
                child: Text(
                  notice,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 与设备存在时差时给出「时间按 X 显示」的说明，否则返回 null。
  static String? _timezoneNotice(TripPlan plan) {
    try {
      final reference = plan.days.isEmpty
          ? DateTime.now().toUtc()
          : TripTimeZone.toInstant(
              timezone: plan.timezone,
              localDate: plan.days.first.date,
              hour: 12,
            );
      if (!TripTimeZone.differsFromDevice(
        timezone: plan.timezone,
        instant: reference,
      )) {
        return null;
      }
      final difference = TripTimeZone.formatOffsetDifference(
        timezone: plan.timezone,
        instant: reference,
      );
      return '时间按 ${plan.timezone} 显示（与你所在地相差 $difference）';
    } on TripTimeZoneException {
      // 时区无法识别时不标注：此时时间已退回设备时区，标注反而是误导。
      return null;
    }
  }
}

/// 多选态下的批量操作条。
///
/// 悬浮在底部而非顶部：拇指可及，且不遮挡页头的行程信息。
class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.count,
    this.onCancelSelected,
    this.onDeleteSelected,
    this.onExit,
  });

  final int count;
  final VoidCallback? onCancelSelected;
  final VoidCallback? onDeleteSelected;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm,
          vertical: AppTokens.spaceXs,
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '退出多选',
              onPressed: onExit,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '已选 $count 项',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton.icon(
              onPressed: onCancelSelected,
              icon: const Icon(Icons.event_busy_outlined, size: 18),
              label: const Text('取消'),
            ),
            TextButton.icon(
              onPressed: onDeleteSelected,
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripLoading extends StatelessWidget {
  const _TripLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView(
      key: key,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: [
        TripLoadingBlock(height: 112, color: color),
        const SizedBox(height: AppTokens.spaceMd),
        ...List.generate(
          4,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: TripLoadingBlock(height: 88, color: color),
          ),
        ),
      ],
    );
  }
}
