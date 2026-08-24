import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/app/config/amap_config.dart';
import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/explore/amap_surface.dart';
import 'package:savorseek/features/places/place_detail_sheet.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/places/place_search_controller.dart';
import 'package:savorseek/features/trip/add_place_to_trip.dart';
import 'package:savorseek/features/trip/schedule_picker_sheet.dart';

/// 探索页（P-MAP）。
///
/// 布局约束来自 `docs/develop/1.前端基础结构开发.md`：地图占据除底部
/// Agent 指令栏外的全部可用空间，指令栏固定在底部不随地图消失。
///
/// 指令栏当前承担地点检索：Agent 编排尚未落地，先把输入直接作为关键词检索，
/// 让「下达指令 → 地图上看到结果」这条路径可用。接入真实编排后，这里改为提交
/// 结构化指令，检索由 Agent 的 `search_places` 工具发起。
class ExplorePage extends StatefulWidget {
  const ExplorePage({
    super.key,
    this.placeRepository,
    this.scheduler,
    this.consent,
  });

  /// 地点检索仓库。为空时检索入口禁用（未注入后端依赖的场景）。
  final PlaceRepository? placeRepository;

  /// 加入行程的能力。为空时详情面板的按钮禁用。
  final PlaceScheduler? scheduler;

  /// 高德合规同意状态。
  ///
  /// 由外部注入时与行程页共享同一实例：同意与否是同一个事实，留在页面内会让
  /// 用户在两处各同意一次。为空时本页自建（测试与未注入依赖的场景）。
  final AmapConsent? consent;

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  /// 默认检索城市。定位能力接入前的回退值，与地图默认视野保持一致。
  static const String _defaultCity = '大连';

  /// 合规同意状态。注入时与行程页共享，否则本页自持。
  late final AmapConsent _consent = widget.consent ?? AmapConsent();

  /// 是否由本页创建 [_consent]，决定 dispose 时是否释放。
  ///
  /// 注入的实例由 AppDependencies 持有并被行程页共用，本页释放会让另一页
  /// 监听一个已销毁的 notifier。
  bool get _ownsConsent => widget.consent == null;

  PlaceSearchController? _search;

  /// marker id 到地点的映射。
  ///
  /// 插件的 `Marker` 自行生成 id，`onTap` 只回传该 id，因此必须在构造标记时同步
  /// 记下对应关系。
  final Map<String, Place> _placeByMarkerId = {};
  Set<Marker> _markers = const <Marker>{};

  /// 已构造标记的那一份结果，用于避免重复构造（见 [_resolveMarkers]）。
  Object? _markersSource;

  bool _isAddingToTrip = false;

  @override
  void initState() {
    super.initState();
    _consent.addListener(_onConsentChanged);
    final repository = widget.placeRepository;
    if (repository != null) {
      _search = PlaceSearchController(repository)
        ..addListener(_onSearchChanged);
    }
  }

  void _onConsentChanged() => setState(() {});
  void _onSearchChanged() => setState(() {});

  @override
  void dispose() {
    _consent.removeListener(_onConsentChanged);
    if (_ownsConsent) _consent.dispose();
    _search?.removeListener(_onSearchChanged);
    _search?.dispose();
    super.dispose();
  }

  Future<void> _submitCommand(String command) async {
    // 城市固定为默认视野所在城市：定位能力尚未接入，不限定城市会让「烧烤」
    // 这类通用词返回外地结果。
    await _search?.searchByKeywords(command, city: _defaultCity);
  }

  /// 加入行程：先取排期上下文，再让用户选年月日时分，最后写入。
  ///
  /// 顺序不能颠倒——时间选择器需要行程已有的日期列表来限定可选范围，而库端要求
  /// 项归属的 trip_day 必须已存在。
  Future<void> _addSelectedToTrip() async {
    final place = _search?.selected;
    final scheduler = widget.scheduler;
    if (place == null || scheduler == null || _isAddingToTrip) return;

    setState(() => _isAddingToTrip = true);
    try {
      final trip = await scheduler.loadContext();
      if (!mounted) return;
      if (trip == null) {
        _showMessage('还没有可加入的行程，请先在行程页创建一个。');
        return;
      }

      final selection = await showSchedulePickerSheet(
        context,
        placeName: place.name,
        trip: trip,
      );
      // 用户取消时静默返回：他没有失败，不该看到提示。
      if (selection == null || !mounted) return;

      await scheduler.add(place: place, trip: trip, selection: selection);
      if (!mounted) return;
      _search?.clearSelection();
      _showMessage(
        '已加入行程：${place.name}（'
        '${formatLocalDate(selection.day.localDate)} '
        '${formatWallClock(selection.hour, selection.minute)}）',
      );
    } on Exception catch (error) {
      if (!mounted) return;
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _isAddingToTrip = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final search = _search;

    return Column(
      children: [
        // Expanded 使地图吃掉除指令栏外的全部高度。
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _buildMapArea()),
              if (search != null) ..._buildOverlays(search),
            ],
          ),
        ),
        // 指令栏不参与地图区域的尺寸计算，始终贴底。
        AgentCommandBar(
          // 未注入仓库或正在检索时不接受新指令：前者点了没有反馈，
          // 后者会让两次结果竞争。
          onSubmit: search == null || search.isLoading ? null : _submitCommand,
        ),
      ],
    );
  }

  List<Widget> _buildOverlays(PlaceSearchController search) {
    final selected = search.selected;
    final notice = _statusNotice(search);

    return [
      if (search.isLoading)
        const Positioned(
          top: AppTokens.spaceMd,
          left: 0,
          right: 0,
          child: Center(child: _SearchingChip()),
        ),
      // 状态提示浮在地图上方而非替换地图：即使检索失败，用户仍应能继续浏览底图
      // （设计文档 §12「允许查看已有结果」）。
      if (notice != null && selected == null)
        Positioned(
          left: AppTokens.spaceMd,
          right: AppTokens.spaceMd,
          bottom: AppTokens.spaceMd,
          child: notice,
        ),
      if (selected != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: PlaceDetailSheet(
            place: selected,
            onClose: search.clearSelection,
            onAddToTrip: widget.scheduler == null ? null : _addSelectedToTrip,
            isAdding: _isAddingToTrip,
          ),
        ),
    ];
  }

  /// 按状态给出各不相同的提示。
  ///
  /// 设计文档 §12 明确要求不能一律显示「暂未找到」：空结果、数据源不可用、
  /// 视野无效、未登录是不同的成因，对应的下一步动作也不同。
  Widget? _statusNotice(PlaceSearchController search) {
    return switch (search.state) {
      PlaceSearchEmpty(:final keywords) => _MapNotice(
        icon: Icons.search_off,
        message: '没有找到与「$keywords」相符的地点。换个说法或扩大范围再试试。',
      ),
      PlaceSearchFailed(:final message, :final failure, :final isRetryable) =>
        _MapNotice(
          icon: _iconFor(failure),
          message: message,
          onRetry: isRetryable ? () => search.retry(city: _defaultCity) : null,
        ),
      _ => null,
    };
  }

  static IconData _iconFor(PlaceSearchFailure failure) {
    return switch (failure) {
      PlaceSearchFailure.network => Icons.wifi_off,
      PlaceSearchFailure.unauthenticated => Icons.lock_outline,
      PlaceSearchFailure.providerKeyMissing ||
      PlaceSearchFailure.providerKeyRejected ||
      PlaceSearchFailure.notConfigured => Icons.vpn_key_off_outlined,
      PlaceSearchFailure.providerQuotaExceeded => Icons.hourglass_bottom,
      PlaceSearchFailure.invalidRequest => Icons.error_outline,
      _ => Icons.cloud_off,
    };
  }

  Widget _buildMapArea() {
    // iOS 的 Key 只能经 Dart 注入，缺失时显式说明，避免白屏无法区分
    // 「未配置」「鉴权失败」「网络异常」三种原因。
    // Android 的 Key 在构建期注入 manifest，由 Gradle 侧校验，此处恒为 false。
    if (AmapConfig.isKeyMissing) {
      return const _MapUnavailableNotice(
        message:
            '未配置 iOS 端高德地图 Key，地图无法显示。\n'
            '请在 amap.env 中填入 AMAP_IOS_KEY，'
            '并在构建时附加 --dart-define-from-file=amap.env。',
      );
    }

    if (!_consent.agreed) {
      return AmapConsentNotice(onAgree: _consent.agree);
    }

    return AmapSurface(
      markers: _resolveMarkers(),
      onMapTap: (_) => _search?.clearSelection(),
    );
  }

  /// 构造当前结果对应的标记集合，并同步 marker id → place 映射。
  ///
  /// 同一批结果只构造一次：`Marker` 的 id 在构造时生成且不可指定，重复构造会让
  /// 插件把「同一批地点」判定为全删全增，地图上出现可见闪烁。
  Set<Marker> _resolveMarkers() {
    final state = _search?.state;

    if (state is! PlaceSearchLoaded) {
      if (_markersSource != null) {
        _markersSource = null;
        _markers = const <Marker>{};
        _placeByMarkerId.clear();
      }
      return _markers;
    }

    if (identical(_markersSource, state.result)) return _markers;

    _placeByMarkerId.clear();
    final markers = <Marker>{};
    for (final place in state.places) {
      // 无坐标的地点无法落点，跳过而非落在 (0,0)——那会在几内亚湾出现幽灵标记。
      if (!place.hasCoordinates) continue;
      final marker = Marker(
        position: LatLng(place.latitude!, place.longitude!),
        infoWindow: InfoWindow(
          title: place.name,
          snippet: place.primaryCategory,
        ),
        onTap: _onMarkerTapped,
      );
      _placeByMarkerId[marker.id] = place;
      markers.add(marker);
    }
    _markersSource = state.result;
    _markers = Set.unmodifiable(markers);
    return _markers;
  }

  void _onMarkerTapped(String markerId) {
    final place = _placeByMarkerId[markerId];
    if (place == null) return;
    _search?.select(place);
  }
}

/// 检索进行中的浮标。
class _SearchingChip extends StatelessWidget {
  const _SearchingChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.inverseSurface,
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: AppTokens.spaceSm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onInverseSurface,
              ),
            ),
            const SizedBox(width: AppTokens.spaceSm),
            Text(
              '正在查找…',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onInverseSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 浮在地图上的状态提示。
class _MapNotice extends StatelessWidget {
  const _MapNotice({required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;

  /// 为空时不显示重试按钮。配置类错误重试永远不会成功，给按钮只会误导用户。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppTokens.spaceSm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: AppTokens.spaceSm),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

class _MapUnavailableNotice extends StatelessWidget {
  const _MapUnavailableNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.map_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('地图不可用', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
