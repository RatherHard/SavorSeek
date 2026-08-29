import 'dart:async';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/app/config/amap_config.dart';
import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/agent/agent_context.dart';
import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/agent/agent_workspace_panel.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/explore/amap_surface.dart';
import 'package:savorseek/features/explore/place_results_drawer.dart';
import 'package:savorseek/features/explore/map_viewport.dart';
import 'package:savorseek/features/explore/map_marker_selection.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';
import 'package:savorseek/features/places/favorites_controller.dart';
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
    this.favoriteController,
    this.auth,
    this.scheduler,
    this.consent,
    this.agentController,
  });

  /// 地点检索仓库。为空时检索入口禁用（未注入后端依赖的场景）。
  final PlaceRepository? placeRepository;

  /// 加入行程的能力。为空时详情面板的按钮禁用。
  final PlaceScheduler? scheduler;

  /// 高德合规同意状态。
  final AmapConsent? consent;

  /// 与「我的」页共享的用户收藏状态。
  final FavoritesController? favoriteController;

  /// 认证能力，用于未登录收藏时打开登录引导。
  final AuthService? auth;

  final AgentController? agentController;

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

  AMapController? _mapController;
  Timer? _viewportDebounce;
  String? _scheduledViewportKey;
  Size? _mapSize;
  CameraPosition? _lastCameraPosition;
  MapMarkerSelectionResult? _markerSelection;
  bool _isAddingToTrip = false;

  @override
  void initState() {
    super.initState();
    _consent.addListener(_onConsentChanged);
    widget.favoriteController?.addListener(_onFavoritesChanged);
    widget.agentController?.addListener(_onAgentChanged);
    final repository = widget.placeRepository;
    if (repository != null) {
      _search = PlaceSearchController(repository)
        ..addListener(_onSearchChanged);
    }
  }

  void _onConsentChanged() => setState(() {});
  void _onSearchChanged() {
    _refreshMarkerSelection();
    if (mounted) setState(() {});
  }

  void _onFavoritesChanged() => setState(() {});
  void _onAgentChanged() {
    if (mounted) setState(() {});
  }

  void _onCameraMoveEnd(CameraPosition position) {
    _lastCameraPosition = position;
    final size = _mapSize;
    if (size != null) {
      _refreshMarkerSelection();
      _scheduleViewportSearch(position, size);
    }
  }

  void _onMapSizeChanged(Size size) {
    if (size.width <= 0 || size.height <= 0 || size == _mapSize) return;
    _mapSize = size;
    final position = _lastCameraPosition;
    if (position != null) _scheduleViewportSearch(position, size);
    _refreshMarkerSelection();
  }

  void _scheduleViewportSearch(CameraPosition position, Size size) {
    final search = _search;
    if (search == null || widget.auth?.isSignedIn != true) return;

    _viewportDebounce?.cancel();
    _viewportDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final query = buildMapViewportQuery(
        latitude: position.target.latitude,
        longitude: position.target.longitude,
        zoom: position.zoom,
        width: size.width,
        height: size.height,
      );
      if (query == null || query.key == _scheduledViewportKey) return;
      _scheduledViewportKey = query.key;
      unawaited(() async {
        await search.searchAround(
          latitude: query.center.latitude,
          longitude: query.center.longitude,
          radiusMeters: query.radiusMeters,
          queryKey: query.key,
        );
        if (mounted && _scheduledViewportKey == query.key) {
          _scheduledViewportKey = null;
        }
      }());
    });
  }

  void _onMapCreated(AMapController controller) {
    _mapController = controller;
    _lastCameraPosition = AmapSurface.initialCamera;
    final size = _mapSize;
    if (size != null) _scheduleViewportSearch(AmapSurface.initialCamera, size);
  }

  @override
  void dispose() {
    _consent.removeListener(_onConsentChanged);
    _viewportDebounce?.cancel();
    if (_ownsConsent) _consent.dispose();
    _search?.removeListener(_onSearchChanged);
    widget.favoriteController?.removeListener(_onFavoritesChanged);
    widget.agentController?.removeListener(_onAgentChanged);
    _search?.dispose();
    super.dispose();
  }

  Future<void> _submitCommand(String command) async {
    final agent = widget.agentController;
    if (agent != null) {
      final position = _lastCameraPosition ?? AmapSurface.initialCamera;
      final size = _mapSize;
      final viewport = size == null
          ? null
          : buildMapViewportQuery(
              latitude: position.target.latitude,
              longitude: position.target.longitude,
              zoom: position.zoom,
              width: size.width,
              height: size.height,
            );
      await agent.submit(
        command,
        context: AgentSubmitContext(
          mapViewport: viewport == null
              ? null
              : AgentMapViewport.fromQuery(viewport),
          selectedPlaceIds: [?_search?.selected?.id],
        ),
      );
      return;
    }
    await _search?.searchByKeywords(command, city: _defaultCity);
    if (!mounted) return;
    final state = _search?.state;
    if (state is PlaceSearchLoaded) {
      await widget.favoriteController?.loadFavoritePlaceIds(
        placeIds: state.places.map((place) => place.id),
      );
    }
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              if (width.isFinite && height.isFinite) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _onMapSizeChanged(Size(width, height));
                });
              }
              return Stack(
                children: [
                  Positioned.fill(child: _buildMapArea()),
                  if (search != null) ..._buildOverlays(search),
                  if (widget.agentController != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !widget.agentController!.hasSession,
                        child: AgentWorkspacePanel(
                          controller: widget.agentController!,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        // 指令栏不参与地图区域的尺寸计算，始终贴底。
        AgentCommandBar(
          // 未注入仓库或正在检索时不接受新指令：前者点了没有反馈，
          // 后者会让两次结果竞争。
          onSubmit:
              search == null ||
                  search.isLoading ||
                  widget.agentController?.isSubmitting == true
              ? null
              : _submitCommand,
        ),
      ],
    );
  }

  void _selectPlaceFromList(Place place) {
    _search?.select(place);
    final controller = _mapController;
    if (controller == null || !place.hasCoordinates) return;
    unawaited(
      controller.moveCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(place.latitude!, place.longitude!),
          16,
        ),
      ),
    );
  }

  bool _isFavoritePending(String placeId) {
    final state = widget.favoriteController!.mutationState(placeId);
    return state == FavoriteMutationState.saving ||
        state == FavoriteMutationState.removing;
  }

  List<Widget> _buildOverlays(PlaceSearchController search) {
    final selected = search.selected;
    final notice = _statusNotice(search);
    final foodPlaces = filterFoodPlaces(search.visiblePlaces);

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
      if (widget.favoriteController != null &&
          (foodPlaces.isNotEmpty || _hasPartialResult(search)))
        Positioned.fill(
          child: PlaceResultsDrawer(
            places: foodPlaces,
            favorites: widget.favoriteController!,
            selectedPlaceId: selected?.id,
            onSelect: _selectPlaceFromList,
            onToggleFavorite: (placeId) =>
                widget.favoriteController!.toggle(placeId),
            onRetryFavorite: (placeId) =>
                widget.favoriteController!.retry(placeId),
            hasMore: search.hasMore,
            isLoadingMore: search.isLoadingMore,
            paginationError: search.state is PlaceSearchLoaded
                ? (search.state as PlaceSearchLoaded).loadMoreError
                : null,
            onLoadMore: search.hasMore ? search.loadMore : null,
            onRetryPagination:
                search.state is PlaceSearchLoaded &&
                    (search.state as PlaceSearchLoaded).loadMoreError != null
                ? search.loadMore
                : null,
            isPartial: _hasPartialResult(search),
            onRetryPartial: _hasPartialResult(search) ? search.retry : null,
            onUnauthenticatedFavorite: widget.auth?.isSignedIn == false
                ? (_) async {
                    await showAuthSheet(context, auth: widget.auth!);
                  }
                : null,
          ),
        ),
      if (selected != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: PlaceDetailSheet(
            place: selected,
            onClose: search.clearSelection,
            isFavorite: widget.favoriteController?.isFavorite(selected.id),
            isFavoritePending: widget.favoriteController == null
                ? false
                : _isFavoritePending(selected.id),
            onFavorite: widget.auth?.isSignedIn == true
                ? () => widget.favoriteController!.toggle(selected.id)
                : null,
            onUnauthenticatedFavorite: widget.auth?.isSignedIn == false
                ? () async {
                    await showAuthSheet(context, auth: widget.auth!);
                  }
                : null,
            onRetryFavorite: widget.favoriteController == null
                ? null
                : () => widget.favoriteController!.retry(selected.id),
            favoriteError: widget.favoriteController?.errorFor(selected.id),
            onAddToTrip: widget.scheduler == null ? null : _addSelectedToTrip,
            isAdding: _isAddingToTrip,
          ),
        ),
    ];
  }

  bool _hasPartialResult(PlaceSearchController search) {
    final state = search.state;
    return state is PlaceSearchLoaded && state.result.isPartial;
  }

  ///
  /// 设计文档 §12 明确要求不能一律显示「暂未找到」：空结果、数据源不可用、
  /// 视野无效、未登录是不同的成因，对应的下一步动作也不同。
  Widget? _statusNotice(PlaceSearchController search) {
    return switch (search.state) {
      PlaceSearchEmpty(
        :final keywords,
        :final source,
        :final hasPreviousResult,
      ) =>
        _MapNotice(
          icon: Icons.search_off,
          message: source == PlaceSearchSource.viewport
              ? (hasPreviousResult
                    ? '当前地图范围暂无新的地点，仍保留上一批结果。'
                    : '当前地图范围暂无符合条件的地点。')
              : '没有找到与「$keywords」相符的地点。换个说法或扩大范围再试试。',
        ),
      PlaceSearchLoaded(:final result) when result.isPartial => _MapNotice(
        icon: Icons.warning_amber_outlined,
        message: '部分地点已加载，部分区域暂不可用。',
        onRetry: search.retry,
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
      onMapCreated: _onMapCreated,
      onMapTap: (_) => _search?.clearSelection(),
      onCameraMoveEnd: _onCameraMoveEnd,
    );
  }

  /// 使用搜索结果更新自动 marker 选择；结果抽屉使用餐饮类别投影。
  void _refreshMarkerSelection() {
    final size = _mapSize;
    final position = _lastCameraPosition ?? AmapSurface.initialCamera;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    final query = buildMapViewportQuery(
      latitude: position.target.latitude,
      longitude: position.target.longitude,
      zoom: position.zoom,
      width: size.width,
      height: size.height,
    );
    if (query == null) return;
    final currentState = _search?.state;
    final candidateIdentity = currentState is PlaceSearchLoaded
        ? currentState.queryKey ?? currentState.keywords
        : 'search';
    final selection = selectMapMarkers(
      places: _search?.mapPlaces ?? const <Place>[],
      context: MapMarkerSelectionContext(
        centerLatitude: query.center.latitude,
        centerLongitude: query.center.longitude,
        zoom: query.zoom,
        width: query.width,
        height: query.height,
        metersPerPixel: query.metersPerPixel,
        candidateIdentity: candidateIdentity,
        queryRadiusMeters: query.radiusMeters.toDouble(),
      ),
    );
    if (_markerSelection?.selectionKey != selection.selectionKey) {
      _markerSelection = selection;
      _markersSource = null;
      if (mounted) setState(() {});
    }
  }

  /// 构造已筛选结果对应的标记集合，并同步 marker id → 地点映射。
  Set<Marker> _resolveMarkers() {
    final places = _markerSelection?.places ?? const <Place>[];
    if (places.isEmpty) {
      _markersSource = null;
      _markers = const <Marker>{};
      _placeByMarkerId.clear();
      return _markers;
    }

    if (_markersSource == _markerSelection?.selectionKey) return _markers;

    _placeByMarkerId.clear();
    final markers = <Marker>{};
    for (final place in places) {
      // 无坐标的地点无法落点，跳过而非落在 (0,0)——那会在几内亚湾出现幽灵标记。
      if (!place.hasCoordinates) continue;
      final marker = Marker(
        position: LatLng(place.latitude!, place.longitude!),
        infoWindow: InfoWindow(
          title: place.name,
          snippet: [
            ?place.primaryCategory,
            if (place.hasValidRating) '评分 ${place.rating!.toStringAsFixed(1)}',
          ].join(' · '),
        ),
        icon: BitmapDescriptor.defaultMarker,
        zIndex: place.hasValidRating ? place.rating! : 0,
        onTap: _onMarkerTapped,
      );
      _placeByMarkerId[marker.id] = place;
      markers.add(marker);
    }
    _markersSource = _markerSelection?.selectionKey;
    _markers = Set.unmodifiable(markers);
    return _markers;
  }

  void _onMarkerTapped(String markerId) {
    final place = _placeByMarkerId[markerId];
    if (place == null) return;
    _selectPlaceFromList(place);
  }
}

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
