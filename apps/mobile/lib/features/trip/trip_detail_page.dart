import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/places/place_repository.dart';

import 'edit_stop_sheet.dart';
import 'add_stop_sheet.dart';
import 'trip_controller.dart';
import 'trip_lifecycle_action_bar.dart';
import 'trip_lifecycle_actions.dart';
import 'trip_lifecycle_menu.dart';
import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_route_map.dart';
import 'trip_route_page.dart';
import 'trip_route_service.dart';
import 'trip_status_views.dart';
import 'trip_stop_actions.dart';
import 'trip_temporal_status.dart';
import 'trip_time_zone.dart';
import 'trip_timeline.dart';

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
    this.placeRepository,
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

  /// 地点检索能力。为空时不提供「添加地点」入口。
  ///
  /// 地点节点是路线能成立的前提——只有它带坐标。此前唯一入口在探索页，用户在行程
  /// 里发现缺一家店时得先离开行程去搜索再切回来。
  final PlaceRepository? placeRepository;

  @override
  State<TripDetailPage> createState() => _TripDetailPageState();
}

class _TripDetailPageState extends State<TripDetailPage> {
  late final TripController _controller = TripController(
    widget.repository,
    tripId: widget.tripId,
  );

  /// 行程级写入编排，与节点动作分开管理。
  TripLifecycleActions? _lifecycleActions;
  StreamSubscription<TripActionOutcome>? _lifecycleOutcomeSubscription;

  /// 节点写入编排。
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
      final writer = repository as TripWriter;
      final actions = TripStopActions(
        // 显式转换而非依赖类型提升：promotion 不跨越 TripStopActions 内部持有的
        // 闭包边界保留，写成 as 更直白也更稳定。
        writer: writer,
        reload: _controller.load,
      );
      // 结果统一在此变成提示条：SnackBar 需要 context，而编排层刻意不持有它。
      _outcomeSubscription = actions.outcomes.listen(_onOutcome);
      actions.isBusy.addListener(_onStateChanged);
      _actions = actions;

      final lifecycle = TripLifecycleActions(
        writer: writer,
        reload: _controller.load,
      );
      _lifecycleOutcomeSubscription = lifecycle.outcomes.listen(_onOutcome);
      lifecycle.isBusy.addListener(_onStateChanged);
      _lifecycleActions = lifecycle;
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
    _lifecycleOutcomeSubscription?.cancel();
    _actions?.isBusy.removeListener(_onStateChanged);
    _lifecycleActions?.isBusy.removeListener(_onStateChanged);
    _actions?.dispose();
    _lifecycleActions?.dispose();
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
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: undo == null
              ? const Duration(seconds: 3)
              : const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
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

  Future<void> _completeTrip(TripPlan plan) async {
    final lifecycle = _lifecycleActions;
    if (lifecycle == null) return;
    if (!await confirmCompleteTrip(context)) return;
    await lifecycle.complete(plan: plan);
  }

  Future<void> _cancelTrip(TripPlan plan) async {
    final lifecycle = _lifecycleActions;
    if (lifecycle == null) return;
    if (!await confirmCancelTrip(context)) return;
    await lifecycle.cancel(plan: plan);
  }

  Future<void> _deleteTrip(TripPlan plan) async {
    final lifecycle = _lifecycleActions;
    if (lifecycle == null) return;
    if (!await confirmDeleteTrip(context, plan.title)) return;
    if (await lifecycle.delete(plan: plan) && mounted) {
      Navigator.of(context).pop();
    }
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
      case StopAction.edit:
        await _edit(actions, plan, day, stop);
      case StopAction.delete:
        final confirmed = await _confirmDelete(stop);
        if (!confirmed || !mounted) return;
        await actions.delete(plan: plan, stop: stop);
    }
  }

  /// 编辑节点的标题、备注与排期。
  Future<void> _edit(
    TripStopActions actions,
    TripPlan plan,
    TripDay day,
    TripStop stop,
  ) async {
    final days = _dayRefsOf(plan);
    if (days.isEmpty) return;
    final draft = await showEditStopSheet(
      context,
      stop: stop,
      trip: TripSchedulingContext(
        tripId: plan.id,
        revision: plan.revision,
        timezone: plan.timezone,
        days: days,
      ),
    );
    if (draft == null || !mounted) return;

    await actions.editStop(
      plan: plan,
      stop: stop,
      currentDayId: day.id ?? stop.tripDayId ?? draft.selection.day.id,
      currentDayDate: day.date,
      targetDayId: draft.selection.day.id,
      targetDayDate: draft.selection.day.localDate,
      hour: draft.selection.hour,
      minute: draft.selection.minute,
      duration: draft.selection.duration,
      timeSlot: draft.selection.timeSlot,
      title: draft.title,
      notes: draft.notes,
    );
  }

  Future<bool> _confirmDelete(TripStop stop) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个行程项？'),
        content: Text('「${stop.title}」将被彻底删除，无法恢复。'),
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

  /// 批量删除已选项。
  Future<void> _runBatch(TripPlan plan) async {
    final actions = _actions;
    if (actions == null) return;
    final ids = _selectedStopIds.toList(growable: false);
    if (ids.isEmpty) return;

    final confirmed = await _confirmBatchDelete(ids.length);
    if (!confirmed || !mounted) return;
    final succeeded = await actions.batchDelete(plan: plan, stopIds: ids);
    if (succeeded && mounted) _clearSelection();
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

    final days = _dayRefsOf(plan);
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
      placeRepository: widget.placeRepository,
      mapConsent: widget.mapConsent,
    );
    if (draft == null || !mounted) return;

    final place = draft.place;
    if (place == null) {
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
      return;
    }
    await actions.addPlace(
      plan: plan,
      tripDayId: draft.selection.day.id,
      dayDate: draft.selection.day.localDate,
      placeId: place.id,
      title: draft.title,
      latitude: place.latitude,
      longitude: place.longitude,
      hour: draft.selection.hour,
      minute: draft.selection.minute,
      duration: draft.selection.duration,
      timeSlot: draft.selection.timeSlot,
      notes: draft.note,
    );
  }

  /// 行程中可供排期的日期。缺 id 的天来自演示数据，无法作为写入目标。
  List<TripDayRef> _dayRefsOf(TripPlan plan) {
    return plan.days
        .where((item) => item.id != null)
        .map((item) => TripDayRef(id: item.id!, localDate: item.date))
        .toList(growable: false);
  }

  /// 添加一个自由安排节点。
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
          if (state is TripLoaded && _lifecycleActions != null)
            TripLifecycleMenu(
              plan: state.plan,
              onSelected: (action) => switch (action) {
                TripAction.delete => _deleteTrip(state.plan),
              },
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
              onStopAction: _actions == null || plan.isReadOnly
                  ? null
                  : (day, stop, action) =>
                        _handleStopAction(plan, day, stop, action),
              onAddStop: _actions == null || plan.isReadOnly
                  ? null
                  : () => _addStop(plan),
              onCompleteTrip:
                  _lifecycleActions == null || plan.status.isTerminal
                  ? null
                  : () => _completeTrip(plan),
              onCancelTrip: _lifecycleActions == null || plan.status.isTerminal
                  ? null
                  : () => _cancelTrip(plan),
              mapConsent: widget.mapConsent,
              routeService: widget.routeService,
              onOpenRoute: widget.mapConsent == null
                  ? null
                  : () => _openRoute(plan),
              selectedStopIds: plan.isReadOnly ? const {} : _selectedStopIds,
              onToggleSelection: _actions == null || plan.isReadOnly
                  ? null
                  : _toggleSelection,
              onClearSelection: plan.isReadOnly ? null : _clearSelection,
              onBatchDelete: plan.isReadOnly ? null : () => _runBatch(plan),
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
    this.onCompleteTrip,
    this.onCancelTrip,
    this.mapConsent,
    this.routeService,
    this.onOpenRoute,
    this.selectedStopIds = const {},
    this.onToggleSelection,
    this.onClearSelection,
    this.onBatchDelete,
  });

  final TripPlan plan;

  /// 行程项操作回调。为空时不给出操作入口。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

  /// 添加行程节点。为空时不给出入口。
  final VoidCallback? onAddStop;
  final VoidCallback? onCompleteTrip;
  final VoidCallback? onCancelTrip;

  final AmapConsent? mapConsent;
  final TripRouteService? routeService;

  /// 打开全屏路线视图。为空时小地图不可点。
  final VoidCallback? onOpenRoute;

  final Set<String> selectedStopIds;
  final ValueChanged<TripStop>? onToggleSelection;
  final VoidCallback? onClearSelection;
  final VoidCallback? onBatchDelete;

  bool get _isSelecting => selectedStopIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final scroll = _buildScrollView(context);
    if (onAddStop == null &&
        onCompleteTrip == null &&
        onCancelTrip == null &&
        !_isSelecting) {
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
              onDeleteSelected: onBatchDelete,
              onExit: onClearSelection,
            ),
          )
        else if (onAddStop != null ||
            onCompleteTrip != null ||
            onCancelTrip != null)
          Positioned(
            left: AppTokens.spaceMd,
            right: AppTokens.spaceMd,
            bottom: AppTokens.spaceMd,
            child: TripLifecycleActionBar(
              onComplete: onCompleteTrip,
              onCancel: onCancelTrip,
              onAddStop: onAddStop,
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
            // 没有坐标节点时的退化说明仍可提供添加入口；统一入口会同时支持地点与普通节点。
            child: plan.hasRoute && mapConsent != null
                ? TripRouteMap(
                    plan: plan,
                    consent: mapConsent!,
                    routeService: routeService,
                    onTap: onOpenRoute,
                  )
                : TripMapFallback(state: plan.mapState, onAddPlace: onAddStop),
          ),
        ),
        SliverPadding(
          // 底部留出浮动按钮的高度，否则最后一张卡片会被按钮压住无法操作。
          padding: EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceLg,
            AppTokens.spaceMd,
            onAddStop == null && onCompleteTrip == null && onCancelTrip == null
                ? AppTokens.spaceXl
                : 180,
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
    final displayStatus = resolveTripDisplayStatus(
      persistedStatus: plan.status,
      startDate: plan.days.isEmpty ? DateTime.now() : plan.days.first.date,
      endDate: plan.days.isEmpty ? DateTime.now() : plan.days.last.date,
      timezone: plan.timezone,
      now: DateTime.now().toUtc(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          plan.destination,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppTokens.spaceSm),
        Text(
          tripDisplayStatusLabel(displayStatus),
          style: theme.textTheme.labelMedium?.copyWith(
            color: tripDisplayStatusColor(context, displayStatus),
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
    this.onDeleteSelected,
    this.onExit,
  });

  final int count;
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
