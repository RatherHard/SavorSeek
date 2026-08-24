import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';
import 'package:savorseek/features/explore/amap_consent.dart';

import 'add_place_to_trip.dart';
import 'add_stop_sheet.dart';
import 'create_trip_sheet.dart';
import 'schedule_picker_sheet.dart';
import 'timezone_picker_sheet.dart';
import 'trip_controller.dart';
import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_route_map.dart';
import 'trip_route_page.dart';
import 'trip_route_service.dart';
import 'trip_switcher_sheet.dart';
import 'trip_time_zone.dart';

class TripPage extends StatefulWidget {
  const TripPage({
    super.key,
    required this.repository,
    this.auth,
    this.mapConsent,
    this.routeService,
  });

  final TripRepository repository;

  /// 认证服务。为空时不提供登录入口，仅展示错误原因。
  final AuthService? auth;

  /// 高德合规同意状态。为空时不显示路线地图（Widget 测试无法初始化地图 SDK）。
  final AmapConsent? mapConsent;

  /// 真实路网路线来源。为空时地图退化为直线连接。
  final TripRouteService? routeService;

  @override
  State<TripPage> createState() => _TripPageState();
}

class _TripPageState extends State<TripPage> {
  late final TripController _controller = TripController(widget.repository);
  StreamSubscription<String?>? _authSubscription;

  /// 创建进行中，用于阻止重复提交。
  bool _isCreating = false;

  /// 改期进行中，用于阻止重复提交。
  bool _isRescheduling = false;

  /// 已选中的行程项 id。非空即处于多选态。
  ///
  /// 只存 id 而非 TripStop：每次重载都会得到新的对象，存实例会在重载后失配。
  final Set<String> _selectedStopIds = {};

  void _toggleSelection(TripStop stop) {
    setState(() {
      if (!_selectedStopIds.remove(stop.id)) _selectedStopIds.add(stop.id);
    });
  }

  void _clearSelection() {
    if (_selectedStopIds.isEmpty) return;
    setState(_selectedStopIds.clear);
  }

  /// 批量取消或删除已选项。
  ///
  /// 走批量 RPC 而非循环单项：每次单项写入都会递增 revision，循环到第二次
  /// 就会因 expected_revision 过期收到 P0002。
  Future<void> _runBatch(TripPlan plan, {required bool isDelete}) async {
    final ids = _selectedStopIds.toList(growable: false);
    if (ids.isEmpty) return;

    if (isDelete) {
      final confirmed = await _confirmBatchDelete(ids.length);
      if (!confirmed || !mounted) return;
    }

    await _runStopWrite(
      plan,
      (writer) => isDelete
          ? writer.batchDeleteTripItems(
              tripId: plan.id,
              expectedRevision: plan.revision,
              tripItemIds: ids,
            )
          : writer.batchCancelTripItems(
              tripId: plan.id,
              expectedRevision: plan.revision,
              tripItemIds: ids,
            ),
      success: isDelete ? '已删除 ${ids.length} 个行程项' : '已取消 ${ids.length} 个行程项',
      // 批量取消的逆操作是逐项恢复；硬删除无法撤销（记录已不存在）。
      undo: isDelete
          ? null
          : (writer, revision) async {
              // 逐项恢复而非批量：restore 每次递增一次 revision，因此必须
              // 顺着上一次返回的值往下走，沿用同一个会从第二项起报 P0002。
              var next = revision;
              for (final id in ids) {
                final result = await writer.restoreTripItem(
                  tripId: plan.id,
                  expectedRevision: next,
                  tripItemId: id,
                );
                next = result.revision;
              }
            },
    );
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

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onStateChanged);
    // 登录/登出后行程可见性会变，重新拉取而不是让用户手动刷新。
    _authSubscription = widget.auth?.userIdChanges.listen((_) {
      _controller.load();
    });
    _controller.load();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _controller
      ..removeListener(_onStateChanged)
      ..dispose();
    super.dispose();
  }

  void _onStateChanged() => setState(() {});

  Future<void> _signIn() async {
    final auth = widget.auth;
    if (auth == null) return;
    final didSignIn = await showAuthSheet(context, auth: auth);
    // 会话流已订阅，登录成功会自动触发重载；此处仅兜住未订阅到的情况。
    if (didSignIn && mounted) await _controller.load();
  }

  /// 创建行程。
  ///
  /// 写入只对 [SupabaseTripRepository] 可用：其余实现（未配置、演示、内存）没有
  /// 写入能力，此时不提供入口而非让按钮点了报错。
  Future<void> _createTrip() async {
    final repository = widget.repository;
    if (repository is! SupabaseTripRepository || _isCreating) return;

    final draft = await showCreateTripSheet(context);
    if (draft == null || !mounted) return;

    setState(() => _isCreating = true);
    // 幂等键在本次操作内固定：冲突重试时复用，避免创建出第二个行程。
    final keys = CreateTripKeys();
    try {
      await repository.createTripWithDays(
        title: draft.title,
        startDate: draft.startDate,
        endDate: draft.endDate,
        partySize: draft.partySize,
        budgetLimitMinor: draft.budgetLimitMinor,
        timezone: draft.timezone,
        keys: keys,
      );
      if (!mounted) return;
      await _controller.load();
      if (mounted) _showMessage('已创建行程：${draft.title}');
    } on TripRepositoryException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
      // 冲突意味着服务端状态已变，重新读一次让 UI 与之对齐。
      if (error.kind == TripRepositoryErrorKind.conflict) {
        await _controller.load();
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  /// 改期：调整某个行程项的日期与时间。
  ///
  /// [TripStop.startAt] 已是行程时区下的墙上时间（见 TripMapper），可直接作为
  /// 选择器初值，无需再做时区换算——若此处再折算一次就会双重偏移。
  Future<void> _rescheduleStop(
    TripPlan plan,
    TripDay day,
    TripStop stop,
  ) async {
    final repository = widget.repository;
    final dayId = day.id ?? stop.tripDayId;
    // 显式转换而非依赖类型提升：repository 在后续 await 与闭包中被引用，
    // 提升不会跨越这些边界保留，写成 as 更直白也更稳定。
    if (repository is! TripWriter) return;
    if (dayId == null || _isRescheduling) return;
    final writer = repository as TripWriter;

    // 行程的全部日期都可作为目标，跨天移动由服务端重算 position。
    final days = plan.days
        .where((item) => item.id != null)
        .map((item) => TripDayRef(id: item.id!, localDate: item.date))
        .toList(growable: false);
    if (days.isEmpty) return;

    final trip = TripSchedulingContext(
      tripId: plan.id,
      revision: plan.revision,
      timezone: plan.timezone,
      days: days,
    );
    final current = days.firstWhere(
      (item) => item.id == dayId,
      orElse: () => days.first,
    );

    final selection = await showSchedulePickerSheet(
      context,
      placeName: stop.title,
      trip: trip,
      isReschedule: true,
      initial: ScheduleSelection(
        day: current,
        hour: stop.startAt.hour,
        minute: stop.startAt.minute,
        duration: stop.endAt.difference(stop.startAt),
      ),
    );
    if (selection == null || !mounted) return;

    setState(() => _isRescheduling = true);
    try {
      final start = resolveInstant(
        localDate: selection.day.localDate,
        timezone: plan.timezone,
        hour: selection.hour,
        minute: selection.minute,
      );
      await writer.rescheduleTripItem(
        tripId: plan.id,
        expectedRevision: plan.revision,
        tripItemId: stop.id,
        tripDayId: selection.day.id,
        plannedStartAt: start,
        plannedEndAt: start.add(selection.duration),
        timeSlot: selection.timeSlot,
      );
      if (!mounted) return;
      await _controller.load();
      if (mounted) {
        _showMessage(
          '已改期：${stop.title}',
          // 撤销需要写入前的原值：原所属日与原起止时刻。这些必须在此处从
          // 改期前的 stop 上取，写入成功后再读已经是新值了。
          undo: (writer, revision) => writer.rescheduleTripItem(
            tripId: plan.id,
            expectedRevision: revision,
            tripItemId: stop.id,
            tripDayId: dayId,
            plannedStartAt: resolveInstant(
              localDate: current.localDate,
              timezone: plan.timezone,
              hour: stop.startAt.hour,
              minute: stop.startAt.minute,
            ),
            plannedEndAt: resolveInstant(
              localDate: current.localDate,
              timezone: plan.timezone,
              hour: stop.startAt.hour,
              minute: stop.startAt.minute,
            ).add(stop.endAt.difference(stop.startAt)),
            timeSlot: stop.type,
          ),
        );
      }
    } on TripRepositoryException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
      // 冲突说明服务端已变，重新读一次让 revision 与 UI 对齐后用户可重试。
      if (error.kind == TripRepositoryErrorKind.conflict) {
        await _controller.load();
      }
    } on TripTimeZoneException catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _isRescheduling = false);
    }
  }

  /// 分派行程项操作。
  ///
  /// 集中一处而非各自接线：四种操作的错误处理、冲突重载与忙碌互斥完全相同，
  /// 分开写必然漏掉其中一条。
  Future<void> _handleStopAction(
    TripPlan plan,
    TripDay day,
    TripStop stop,
    StopAction action,
  ) async {
    switch (action) {
      case StopAction.reschedule:
        await _rescheduleStop(plan, day, stop);
      case StopAction.cancel:
        await _runStopWrite(
          plan,
          (writer) => writer.cancelTripItem(
            tripId: plan.id,
            expectedRevision: plan.revision,
            tripItemId: stop.id,
          ),
          success: '已取消：${stop.title}',
          // 取消的逆操作即恢复，无需额外快照。
          undo: (writer, revision) => writer.restoreTripItem(
            tripId: plan.id,
            expectedRevision: revision,
            tripItemId: stop.id,
          ),
        );
      case StopAction.restore:
        await _runStopWrite(
          plan,
          (writer) => writer.restoreTripItem(
            tripId: plan.id,
            expectedRevision: plan.revision,
            tripItemId: stop.id,
          ),
          success: '已恢复：${stop.title}',
        );
      case StopAction.delete:
        // 硬删除不可恢复，必须二次确认。取消同样能让项从计划中消失，
        // 且可反悔，因此确认框里把这条区别讲清楚。
        final confirmed = await _confirmDelete(stop);
        if (!confirmed || !mounted) return;
        await _runStopWrite(
          plan,
          (writer) => writer.deleteTripItem(
            tripId: plan.id,
            expectedRevision: plan.revision,
            tripItemId: stop.id,
          ),
          success: '已删除：${stop.title}',
        );
    }
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

  /// 执行一次行程项写入，统一处理忙碌互斥、冲突重载与提示。
  ///
  /// [undo] 非空时在提示条上给出「撤销」。撤销所需的原值必须由调用方在写入前
  /// 留存：写入成功后再去读已经是新值了。
  Future<void> _runStopWrite(
    TripPlan plan,
    Future<Object?> Function(TripWriter writer) write, {
    required String success,
    Future<void> Function(TripWriter writer, int revision)? undo,
  }) async {
    final repository = widget.repository;
    if (repository is! TripWriter || _isRescheduling) return;
    final writer = repository as TripWriter;

    setState(() => _isRescheduling = true);
    try {
      await write(writer);
      if (!mounted) return;
      await _controller.load();
      if (mounted) _showMessage(success, undo: undo);
    } on TripRepositoryException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
      if (error.kind == TripRepositoryErrorKind.conflict) {
        await _controller.load();
      }
    } finally {
      if (mounted) setState(() => _isRescheduling = false);
    }
  }

  /// 执行一次撤销。
  ///
  /// 撤销本身也是一次写入，因此必须用「撤销时」的最新 revision，而不是被撤销的
  /// 那次操作所用的旧值——后者早已过期，必然收到 P0002。
  Future<void> _runUndo(
    Future<void> Function(TripWriter writer, int revision) undo,
  ) async {
    final repository = widget.repository;
    if (repository is! TripWriter || _isRescheduling) return;
    final writer = repository as TripWriter;

    // 撤销前重新读一次，取当前 revision。
    final state = _controller.state;
    if (state is! TripLoaded) return;

    setState(() => _isRescheduling = true);
    try {
      await undo(writer, state.plan.revision);
      if (!mounted) return;
      await _controller.load();
      if (mounted) _showMessage('已撤销');
    } on TripRepositoryException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
      if (error.kind == TripRepositoryErrorKind.conflict) {
        await _controller.load();
      }
    } finally {
      if (mounted) setState(() => _isRescheduling = false);
    }
  }

  /// 添加一个自由安排节点。
  ///
  /// 只支持 `break` 项：地点节点必须携带 placeId 与快照（库端 trigger 强制），
  /// 需经探索页选点。此处提供的是「预留一段时间」这类不依赖地点的节点。
  Future<void> _addStop(TripPlan plan) async {
    if (widget.repository is! TripWriter || _isRescheduling) return;

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

    final start = resolveInstant(
      localDate: draft.selection.day.localDate,
      timezone: plan.timezone,
      hour: draft.selection.hour,
      minute: draft.selection.minute,
    );

    // 新项的 id 只能从写入结果里得到，故用一个可变量在两个闭包间传递：
    // 撤销闭包在写入成功后才会被调用，届时已被赋值。
    String? createdId;
    await _runStopWrite(
      plan,
      (writer) async {
        final result = await writer.addBreakItem(
          tripId: plan.id,
          expectedRevision: plan.revision,
          tripDayId: draft.selection.day.id,
          title: draft.title,
          plannedStartAt: start,
          plannedEndAt: start.add(draft.selection.duration),
          timeSlot: draft.selection.timeSlot,
          notes: draft.note,
        );
        createdId = result.id;
        return result;
      },
      success: '已添加节点：${draft.title}',
      // 加入行程的逆操作是删除刚建的那一项。
      undo: (writer, revision) async {
        final id = createdId;
        if (id == null) return;
        await writer.deleteTripItem(
          tripId: plan.id,
          expectedRevision: revision,
          tripItemId: id,
        );
      },
    );
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

  /// 打开行程切换器。
  Future<void> _switchTrip(TripPlan plan, List<TripSummary> trips) async {
    final result = await showTripSwitcherSheet(
      context,
      trips: trips,
      currentTripId: plan.id,
      canCreate: widget.repository is SupabaseTripRepository,
    );
    if (result == null || !mounted) return;

    switch (result) {
      case TripSwitcherSelected(:final tripId):
        await _controller.selectTrip(tripId);
      case TripSwitcherCreate():
        await _createTrip();
    }
  }

  /// 更改行程时区。
  ///
  /// 已排入的项保留当地钟点（19:00 仍是 19:00），UTC 时刻由服务端重算。这是唯一
  /// 能让项继续归属原 trip_day 的语义——保留绝对时刻会让当地日期跳到相邻一天。
  Future<void> _changeTimezone(TripPlan plan) async {
    final picked = await showTimezonePickerSheet(
      context,
      current: plan.timezone,
    );
    if (picked == null || picked == plan.timezone || !mounted) return;

    await _runStopWrite(
      plan,
      (writer) => writer.changeTripTimezone(
        tripId: plan.id,
        expectedRevision: plan.revision,
        timezone: picked,
      ),
      success: '行程时区已改为 $picked，各项保留原当地时间',
    );
  }

  void _showMessage(
    String message, {
    Future<void> Function(TripWriter writer, int revision)? undo,
  }) {
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

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppTokens.durationNormal,
      child: switch (_controller.state) {
        TripLoading() => const _TripLoading(key: ValueKey('loading')),
        TripEmpty() => _TripEmpty(
          key: const ValueKey('empty'),
          // 无写入能力的仓库下置空，由 _TripEmpty 把按钮禁用。
          onCreateTrip: widget.repository is SupabaseTripRepository
              ? _createTrip
              : null,
          isCreating: _isCreating,
        ),
        TripError(
          kind: TripRepositoryErrorKind.unauthenticated,
          :final message,
        ) =>
          _TripSignInPrompt(
            key: const ValueKey('signIn'),
            message: message,
            onSignIn: widget.auth == null ? null : _signIn,
          ),
        TripError(:final message) => _TripError(
          key: const ValueKey('error'),
          message: message,
          onRetry: _controller.load,
        ),
        TripLoaded(:final plan, :final trips) => _TripLoaded(
          key: const ValueKey('loaded'),
          plan: plan,
          trips: trips,
          // 只有真实仓库支持写入；演示与占位实现下不给出操作入口。
          onStopAction: widget.repository is TripWriter
              ? (day, stop, action) =>
                    _handleStopAction(plan, day, stop, action)
              : null,
          onChangeTimezone: widget.repository is TripWriter
              ? () => _changeTimezone(plan)
              : null,
          // 创建行程与项级写入的能力来源不同：前者只有 Supabase 实现具备，
          // 因此不能共用 TripWriter 判断。
          onCreateTrip: widget.repository is SupabaseTripRepository
              ? _createTrip
              : null,
          onAddStop: widget.repository is TripWriter
              ? () => _addStop(plan)
              : null,
          // 只有一个行程时不给切换入口：面板里只会列出当前这一个。
          onSwitchTrip: trips.length > 1
              ? () => _switchTrip(plan, trips)
              : null,
          mapConsent: widget.mapConsent,
          routeService: widget.routeService,
          onOpenRoute: widget.mapConsent == null
              ? null
              : () => _openRoute(plan),
          selectedStopIds: _selectedStopIds,
          onToggleSelection: widget.repository is TripWriter
              ? _toggleSelection
              : null,
          onClearSelection: _clearSelection,
          onBatchCancel: () => _runBatch(plan, isDelete: false),
          onBatchDelete: () => _runBatch(plan, isDelete: true),
        ),
      },
    );
  }
}

/// 未认证态：RLS 下读取恒为空，这不是错误，因此单独呈现为登录引导。
class _TripSignInPrompt extends StatelessWidget {
  const _TripSignInPrompt({
    super.key,
    required this.message,
    required this.onSignIn,
  });

  final String message;
  final Future<void> Function()? onSignIn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                child: Icon(
                  Icons.lock_person_outlined,
                  size: 40,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text('登录后查看行程', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: onSignIn,
              icon: const Icon(Icons.login),
              label: const Text('登录'),
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
    return ListView(
      key: key,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: [
        _LoadingBlock(
          height: 112,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        const SizedBox(height: AppTokens.spaceMd),
        ...List.generate(
          4,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: _LoadingBlock(
              height: 88,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
    );
  }
}

class _TripEmpty extends StatelessWidget {
  const _TripEmpty({
    super.key,
    required this.onCreateTrip,
    this.isCreating = false,
  });

  /// 为空时按钮禁用：后端不可写时点了没有任何反馈。
  final VoidCallback? onCreateTrip;
  final bool isCreating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                child: Icon(
                  Icons.route_outlined,
                  size: 40,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text('暂无行程', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '把想去的美食地点交给 Agent，\n从一顿饭开始安排你的下一段旅程。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: isCreating ? null : onCreateTrip,
              icon: isCreating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(isCreating ? '正在创建…' : '规划一段美食行程'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripError extends StatelessWidget {
  const _TripError({super.key, required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, size: 44, color: scheme.error),
            const SizedBox(height: AppTokens.spaceMd),
            Text('行程暂时加载失败', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '请检查网络后重试。\n$message',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripLoaded extends StatelessWidget {
  const _TripLoaded({
    super.key,
    required this.plan,
    this.trips = const [],
    this.onStopAction,
    this.onChangeTimezone,
    this.onCreateTrip,
    this.onAddStop,
    this.onSwitchTrip,
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

  /// 用户的全部行程，用于在页头标注「第几个 / 共几个」。
  final List<TripSummary> trips;

  /// 行程项操作回调。为空时不给出操作入口。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

  /// 更改行程时区。为空时不给出入口。
  final VoidCallback? onChangeTimezone;

  /// 新建行程。为空时不给出入口。
  final VoidCallback? onCreateTrip;

  /// 添加行程节点。为空时不给出入口。
  final VoidCallback? onAddStop;

  /// 切换行程。为空时不给出入口（只有一个行程或无切换能力）。
  final VoidCallback? onSwitchTrip;

  /// 高德合规同意状态。为空时不渲染地图（测试与未注入依赖时）。
  final AmapConsent? mapConsent;

  /// 真实路网路线来源。为空时地图退化为直线连接。
  final TripRouteService? routeService;

  /// 打开全屏路线视图。为空时小地图不可点。
  final VoidCallback? onOpenRoute;

  /// 已选中的行程项 id。非空即处于多选态。
  final Set<String> selectedStopIds;

  /// 切换某一项的选中状态。为空时不支持多选（无写入能力）。
  final ValueChanged<TripStop>? onToggleSelection;

  /// 退出多选态。
  final VoidCallback? onClearSelection;

  /// 批量取消已选项。
  final VoidCallback? onBatchCancel;

  /// 批量删除已选项。
  final VoidCallback? onBatchDelete;

  bool get _isSelecting => selectedStopIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // 页面本身没有 Scaffold（由 AppShell 提供），因此浮动按钮用 Stack 叠放而非
    // Scaffold.floatingActionButton——后者会要求本页自带 Scaffold，进而在
    // AppShell 的 Scaffold 内再嵌一层，把 SnackBar 的宿主也一并改掉。
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
          sliver: SliverToBoxAdapter(
            child: _TripHeader(
              plan: plan,
              tripCount: trips.length,
              onChangeTimezone: onChangeTimezone,
              onCreateTrip: onCreateTrip,
              onSwitchTrip: onSwitchTrip,
            ),
          ),
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
                : _MapFallback(state: plan.mapState),
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
            itemBuilder: (context, index) => _TripDayTimeline(
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

/// 行程级操作，作用于整个行程而非单个项。
enum TripAction { changeTimezone, createTrip }

class _TripHeader extends StatelessWidget {
  const _TripHeader({
    required this.plan,
    this.tripCount = 1,
    this.onChangeTimezone,
    this.onCreateTrip,
    this.onSwitchTrip,
  });

  final TripPlan plan;

  /// 行程总数，用于在标题旁标注「共 N 个行程」。
  final int tripCount;

  /// 更改时区。为空时不给出入口（无写入能力的仓库）。
  final VoidCallback? onChangeTimezone;

  /// 新建行程。为空时不给出入口。
  final VoidCallback? onCreateTrip;

  /// 切换行程。为空时标题不可点。
  final VoidCallback? onSwitchTrip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tripCount > 1 ? '我的行程 · 共 $tripCount 个' : '我的行程',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: AppTokens.spaceXs),
              // 多行程时标题即切换入口：行程名是用户识别「在看哪一个」的锚点，
              // 把切换挂在它上面比另设一个按钮更直观。
              if (onSwitchTrip case final switchTrip?)
                InkWell(
                  onTap: switchTrip,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          plan.title,
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      Icon(Icons.expand_more, color: scheme.primary),
                    ],
                  ),
                )
              else
                Text(plan.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: AppTokens.spaceXs),
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
                    Icon(
                      Icons.public,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(
                      notice,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        // 行程级操作聚合到一个菜单：入口散落成多个图标时，标题区会被图标挤占，
        // 且「新建行程」这类低频操作不值得常驻一个按钮。
        if (onChangeTimezone != null || onCreateTrip != null)
          PopupMenuButton<TripAction>(
            tooltip: '行程操作',
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) => switch (action) {
              TripAction.changeTimezone => onChangeTimezone?.call(),
              TripAction.createTrip => onCreateTrip?.call(),
            },
            itemBuilder: (context) => [
              if (onChangeTimezone != null)
                const PopupMenuItem(
                  value: TripAction.changeTimezone,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.public),
                    title: Text('更改行程时区'),
                  ),
                ),
              if (onCreateTrip != null)
                const PopupMenuItem(
                  value: TripAction.createTrip,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.add_location_alt_outlined),
                    title: Text('新建行程'),
                  ),
                ),
            ],
          ),
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

class _MapFallback extends StatelessWidget {
  const _MapFallback({required this.state});

  final TripMapState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUnavailable = state == TripMapState.unavailable;
    return Container(
      height: 156,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _MapPatternPainter(color: scheme.outlineVariant),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isUnavailable ? Icons.map_outlined : Icons.map,
                    color: scheme.primary,
                    size: 30,
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    isUnavailable ? '地图路线暂不可用' : '路线地图',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTokens.spaceXs),
                  Text(
                    isUnavailable ? '时间表仍可正常查看，地图接入后会显示路线。' : '查看地点之间的移动顺序与距离。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPatternPainter extends CustomPainter {
  const _MapPatternPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 36) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MapPatternPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _TripDayTimeline extends StatelessWidget {
  const _TripDayTimeline({
    required this.day,
    this.onStopAction,
    this.selectedStopIds = const {},
    this.onToggleSelection,
    this.isSelecting = false,
  });

  final TripDay day;

  /// 行程项操作回调。为空时不给出任何操作入口（无写入能力的仓库）。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

  final Set<String> selectedStopIds;
  final ValueChanged<TripStop>? onToggleSelection;
  final bool isSelecting;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(day.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceMd),
        ...day.stops.asMap().entries.map(
          (entry) => _TimelineStop(
            stop: entry.value,
            isLast: entry.key == day.stops.length - 1,
            isSelected: selectedStopIds.contains(entry.value.id),
            isSelecting: isSelecting,
            // 多选态下点击即切换选中；否则点卡片改期，是最常用的操作。
            onTap: isSelecting
                ? (onToggleSelection == null
                      ? null
                      : () => onToggleSelection!(entry.value))
                : (onStopAction == null || !entry.value.canReschedule
                      ? null
                      : () => onStopAction!(
                          day,
                          entry.value,
                          StopAction.reschedule,
                        )),
            // 长按进入多选：这是列表多选的通用手势，不必额外给一个「选择」按钮。
            onLongPress: onToggleSelection == null
                ? null
                : () => onToggleSelection!(entry.value),
            onMenuAction: onStopAction == null || isSelecting
                ? null
                : (action) => onStopAction!(day, entry.value, action),
          ),
        ),
      ],
    );
  }
}

class _TimelineStop extends StatelessWidget {
  const _TimelineStop({
    required this.stop,
    required this.isLast,
    this.isSelected = false,
    this.isSelecting = false,
    this.onTap,
    this.onLongPress,
    this.onMenuAction,
  });

  final TripStop stop;
  final bool isLast;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<StopAction>? onMenuAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 58,
            child: Column(
              children: [
                Text(
                  _formatTime(stop.startAt),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: AppTokens.spaceSm),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!isLast)
            VerticalDivider(
              width: AppTokens.spaceMd,
              thickness: 1,
              color: scheme.outlineVariant,
            )
          else
            const SizedBox(width: AppTokens.spaceMd),
          Expanded(
            child: _StopCard(
              stop: stop,
              isSelected: isSelected,
              isSelecting: isSelecting,
              onTap: onTap,
              onLongPress: onLongPress,
              onMenuAction: onMenuAction,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _StopCard extends StatelessWidget {
  const _StopCard({
    required this.stop,
    this.isSelected = false,
    this.isSelecting = false,
    this.onTap,
    this.onLongPress,
    this.onMenuAction,
  });

  final TripStop stop;

  final bool isSelected;
  final bool isSelecting;

  /// 为空时卡片不可点：终态项与无写入能力时不该给出可点的错觉。
  final VoidCallback? onTap;

  /// 长按进入多选态。
  final VoidCallback? onLongPress;

  /// 操作菜单回调。为空时不显示菜单。
  final ValueChanged<StopAction>? onMenuAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCancelled = stop.status == TripItemStatus.cancelled;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      elevation: 0,
      // 选中态用主色容器着色：多选时需要一眼看出选了哪几张。
      color: isSelected
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        side: isSelected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        // InkWell 包在 Padding 外层：涟漪应覆盖整张卡片，包在内层只有文字区域响应。
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isSelecting) ...[
                    Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: isSelected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                  ],
                  Expanded(
                    child: Text(
                      stop.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        // 已取消的项加删除线：一眼可辨，且不必读文字就知道状态。
                        decoration: isCancelled
                            ? TextDecoration.lineThrough
                            : null,
                        color: isCancelled ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                  ),
                  if (isCancelled)
                    Text(
                      '已取消',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  if (stop.isLocked)
                    Icon(Icons.lock_outline, size: 17, color: scheme.primary),
                  if (onMenuAction != null) ...[
                    const SizedBox(width: AppTokens.spaceXs),
                    _StopMenu(stop: stop, onSelected: onMenuAction!),
                  ],
                ],
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                stop.subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  decoration: isCancelled ? TextDecoration.lineThrough : null,
                ),
              ),
              if (stop.note case final note?) ...[
                const SizedBox(height: AppTokens.spaceSm),
                Text(
                  note,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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

/// 行程项可执行的操作。
enum StopAction { reschedule, cancel, restore, delete }

/// 行程项的操作菜单。
///
/// 按状态给出不同选项而非全部列出后禁用：终态项的「改期」永远不可用，列出来
/// 只会让用户反复尝试。
class _StopMenu extends StatelessWidget {
  const _StopMenu({required this.stop, required this.onSelected});

  final TripStop stop;
  final ValueChanged<StopAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final isCancelled = stop.status == TripItemStatus.cancelled;
    // 已完成/已跳过的项是历史事实，库端拒绝任何变更，故不给菜单。
    if (stop.status == TripItemStatus.completed ||
        stop.status == TripItemStatus.skipped) {
      return const SizedBox.shrink();
    }

    return PopupMenuButton<StopAction>(
      onSelected: onSelected,
      tooltip: '行程项操作',
      icon: const Icon(Icons.more_vert, size: 18),
      itemBuilder: (context) => [
        if (!isCancelled) ...[
          const PopupMenuItem(
            value: StopAction.reschedule,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_calendar_outlined),
              title: Text('改期'),
            ),
          ),
          const PopupMenuItem(
            value: StopAction.cancel,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.event_busy_outlined),
              title: Text('取消'),
              subtitle: Text('保留记录，可恢复'),
            ),
          ),
        ] else
          const PopupMenuItem(
            value: StopAction.restore,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.restore),
              title: Text('恢复'),
            ),
          ),
        const PopupMenuItem(
          value: StopAction.delete,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('删除'),
            subtitle: Text('不可恢复'),
          ),
        ),
      ],
    );
  }
}
