import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';

import 'add_place_to_trip.dart';
import 'create_trip_sheet.dart';
import 'schedule_picker_sheet.dart';
import 'timezone_picker_sheet.dart';
import 'trip_controller.dart';
import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_time_zone.dart';

class TripPage extends StatefulWidget {
  const TripPage({super.key, required this.repository, this.auth});

  final TripRepository repository;

  /// 认证服务。为空时不提供登录入口，仅展示错误原因。
  final AuthService? auth;

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
      if (mounted) _showMessage('已改期：${stop.title}');
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
          success: '已取消：${stop.title}（可在行程中恢复）',
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
  Future<void> _runStopWrite(
    TripPlan plan,
    Future<Object?> Function(TripWriter writer) write, {
    required String success,
  }) async {
    final repository = widget.repository;
    if (repository is! TripWriter || _isRescheduling) return;
    final writer = repository as TripWriter;

    setState(() => _isRescheduling = true);
    try {
      await write(writer);
      if (!mounted) return;
      await _controller.load();
      if (mounted) _showMessage(success);
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

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
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
        TripLoaded(:final plan) => _TripLoaded(
          key: const ValueKey('loaded'),
          plan: plan,
          // 只有真实仓库支持写入；演示与占位实现下不给出操作入口。
          onStopAction: widget.repository is TripWriter
              ? (day, stop, action) =>
                    _handleStopAction(plan, day, stop, action)
              : null,
          onChangeTimezone: widget.repository is TripWriter
              ? () => _changeTimezone(plan)
              : null,
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
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
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
    this.onStopAction,
    this.onChangeTimezone,
  });

  final TripPlan plan;

  /// 行程项操作回调。为空时不给出操作入口。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

  /// 更改行程时区。为空时不给出入口。
  final VoidCallback? onChangeTimezone;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: key,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceMd,
            AppTokens.spaceMd,
            AppTokens.spaceSm,
          ),
          sliver: SliverToBoxAdapter(
            child: _TripHeader(plan: plan, onChangeTimezone: onChangeTimezone),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
          sliver: SliverToBoxAdapter(child: _MapFallback(state: plan.mapState)),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceLg,
            AppTokens.spaceMd,
            AppTokens.spaceXl,
          ),
          sliver: SliverList.builder(
            itemCount: plan.days.length,
            itemBuilder: (context, index) =>
                _TripDayTimeline(
                  day: plan.days[index],
                  onStopAction: onStopAction,
                ),
          ),
        ),
      ],
    );
  }
}

class _TripHeader extends StatelessWidget {
  const _TripHeader({required this.plan, this.onChangeTimezone});

  final TripPlan plan;

  /// 更改时区。为空时不给出入口（无写入能力的仓库）。
  final VoidCallback? onChangeTimezone;

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
                '我的行程',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: AppTokens.spaceXs),
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
        if (onChangeTimezone != null)
          IconButton(
            tooltip: '更改行程时区',
            onPressed: onChangeTimezone,
            icon: const Icon(Icons.public),
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
  const _TripDayTimeline({required this.day, this.onStopAction});

  final TripDay day;

  /// 行程项操作回调。为空时不给出任何操作入口（无写入能力的仓库）。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

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
            // 点卡片即改期，是最常用的操作；其余操作走菜单。
            onTap: onStopAction == null || !entry.value.canReschedule
                ? null
                : () => onStopAction!(day, entry.value, StopAction.reschedule),
            onMenuAction: onStopAction == null
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
    this.onTap,
    this.onMenuAction,
  });

  final TripStop stop;
  final bool isLast;
  final VoidCallback? onTap;
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
              onTap: onTap,
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
  const _StopCard({required this.stop, this.onTap, this.onMenuAction});

  final TripStop stop;

  /// 为空时卡片不可点：终态项与无写入能力时不该给出可点的错觉。
  final VoidCallback? onTap;

  /// 操作菜单回调。为空时不显示菜单。
  final ValueChanged<StopAction>? onMenuAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCancelled = stop.status == TripItemStatus.cancelled;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: InkWell(
        // InkWell 包在 Padding 外层：涟漪应覆盖整张卡片，包在内层只有文字区域响应。
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
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
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
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
