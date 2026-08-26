import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/places/place_repository.dart';

import 'create_trip_sheet.dart';
import 'trip_detail_page.dart';
import 'trip_list_controller.dart';
import 'trip_repository.dart';
import 'trip_route_service.dart';
import 'trip_status_views.dart';
import 'trip_temporal_status.dart';

/// 行程一级页面：选择要查看的行程。
///
/// 与二级的 [TripDetailPage] 分开而非单页内切换：行程数变多后「在看哪一个」与
/// 「怎么换一个」若都藏在标题的下拉图标里，用户找不到；列表本身就是最直观的
/// 选择界面。
class TripListPage extends StatefulWidget {
  const TripListPage({
    super.key,
    required this.repository,
    this.auth,
    this.mapConsent,
    this.routeService,
    this.placeRepository,
  });

  final TripRepository repository;

  /// 认证服务。为空时不提供登录入口，仅展示错误原因。
  final AuthService? auth;

  /// 高德合规同意状态。为空时详情页不显示路线地图（Widget 测试无法初始化地图 SDK）。
  final AmapConsent? mapConsent;

  /// 真实路网路线来源。为空时详情页的地图退化为直线连接。
  final TripRouteService? routeService;

  /// 地点检索能力。为空时详情页不提供「添加地点」入口。
  final PlaceRepository? placeRepository;

  @override
  State<TripListPage> createState() => _TripListPageState();
}

class _TripListPageState extends State<TripListPage> {
  late final TripListController _controller = TripListController(
    widget.repository,
  );
  StreamSubscription<String?>? _authSubscription;

  /// 创建进行中，用于阻止重复提交。
  bool _isCreating = false;

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

  /// 打开某个行程的详情页。
  ///
  /// push 到根 Navigator，盖住 AppShell 的顶部主导航——进去做事、做完返回，与两级
  /// 结构的语义一致。返回后重新 load：详情页里改了标题或删了节点，列表上的天数与
  /// 更新时间都可能变。
  Future<void> _openTrip(TripSummary trip) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TripDetailPage(
          repository: widget.repository,
          tripId: trip.id,
          auth: widget.auth,
          mapConsent: widget.mapConsent,
          routeService: widget.routeService,
          placeRepository: widget.placeRepository,
        ),
      ),
    );
    if (mounted) await _controller.load();
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

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 新建行程是列表层面的操作，放在这里比藏在某个行程的页头里更合理。
    final canCreate = widget.repository is SupabaseTripRepository;
    return AnimatedSwitcher(
      duration: AppTokens.durationNormal,
      child: switch (_controller.state) {
        TripListLoading() => const _TripListLoading(key: ValueKey('loading')),
        TripListEmpty() => _TripEmpty(
          key: const ValueKey('empty'),
          // 无写入能力的仓库下置空，由 _TripEmpty 把按钮禁用。
          onCreateTrip: canCreate ? _createTrip : null,
          isCreating: _isCreating,
        ),
        TripListError(
          kind: TripRepositoryErrorKind.unauthenticated,
          :final message,
        ) =>
          TripSignInPromptView(
            key: const ValueKey('signIn'),
            message: message,
            onSignIn: widget.auth == null ? null : _signIn,
          ),
        TripListError(:final message) => TripErrorView(
          key: const ValueKey('error'),
          message: message,
          onRetry: _controller.load,
        ),
        TripListLoaded(:final trips) => _TripList(
          key: const ValueKey('loaded'),
          trips: trips,
          onOpenTrip: _openTrip,
          onCreateTrip: canCreate ? _createTrip : null,
          isCreating: _isCreating,
        ),
      },
    );
  }
}

/// 行程卡片列表。
class _TripList extends StatelessWidget {
  const _TripList({
    super.key,
    required this.trips,
    required this.onOpenTrip,
    this.onCreateTrip,
    this.isCreating = false,
  });

  final List<TripSummary> trips;
  final ValueChanged<TripSummary> onOpenTrip;

  /// 新建行程。为空时不给出入口（无写入能力的仓库）。
  final Future<void> Function()? onCreateTrip;
  final bool isCreating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = ListView.builder(
      padding: EdgeInsets.fromLTRB(
        AppTokens.spaceMd,
        AppTokens.spaceMd,
        AppTokens.spaceMd,
        // 底部留出浮动按钮的高度，否则最后一张卡片会被按钮压住无法点击。
        onCreateTrip == null ? AppTokens.spaceXl : 88,
      ),
      itemCount: trips.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trips.length > 1 ? '我的行程 · 共 ${trips.length} 个' : '我的行程',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXs),
                Text('选择一个行程查看安排', style: theme.textTheme.headlineSmall),
              ],
            ),
          );
        }
        final trip = trips[index - 1];
        return _TripCard(trip: trip, onTap: () => onOpenTrip(trip));
      },
    );

    if (onCreateTrip == null) return KeyedSubtree(key: key, child: list);
    return Stack(
      key: key,
      children: [
        Positioned.fill(child: list),
        Positioned(
          right: AppTokens.spaceMd,
          bottom: AppTokens.spaceMd,
          child: FloatingActionButton.extended(
            onPressed: isCreating ? null : onCreateTrip,
            icon: isCreating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: Text(isCreating ? '正在创建…' : '新建行程'),
          ),
        ),
      ],
    );
  }
}

class _TripStatusBadge extends StatelessWidget {
  const _TripStatusBadge({required this.trip});

  final TripSummary trip;

  @override
  Widget build(BuildContext context) {
    final status = resolveTripDisplayStatus(
      persistedStatus: trip.status,
      startDate: trip.startDate,
      endDate: trip.endDate,
      timezone: trip.timezone,
      now: DateTime.now().toUtc(),
    );
    return Text(
      tripDisplayStatusLabel(status),
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: tripDisplayStatusColor(context, status)),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip, required this.onTap});

  final TripSummary trip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceSm),
                  child: Icon(
                    Icons.route_outlined,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            trip.title,
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _TripStatusBadge(trip: trip),
                      ],
                    ),
                    const SizedBox(height: AppTokens.spaceXs),
                    Text(
                      '${_formatDate(trip.startDate)} – '
                      '${_formatDate(trip.endDate)} · 共 ${trip.dayCount} 天',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

class _TripListLoading extends StatelessWidget {
  const _TripListLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView(
      key: key,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: [
        TripLoadingBlock(height: 64, color: color),
        const SizedBox(height: AppTokens.spaceMd),
        ...List.generate(
          3,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: TripLoadingBlock(height: 84, color: color),
          ),
        ),
      ],
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
  final Future<void> Function()? onCreateTrip;
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
