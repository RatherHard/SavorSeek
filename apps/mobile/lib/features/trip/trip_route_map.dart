import 'dart:math' as math;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/explore/amap_surface.dart';

import 'trip_models.dart';
import 'trip_route_service.dart';

/// 行程路线的小地图。
///
/// 只读缩略图：手势全部关闭，点击整块进入全屏查看。固定高度内既要响应地图拖拽
/// 又要让页面滚动是做不到的——两者争夺同一个纵向手势，因此把交互留给全屏视图。
class TripRouteMap extends StatefulWidget {
  const TripRouteMap({
    super.key,
    required this.plan,
    required this.consent,
    this.routeService,
    this.height = 168,
    this.interactive = false,
    this.onTap,
  });

  final TripPlan plan;

  /// 高德合规同意状态。未同意前不渲染地图，而是显示告知卡片。
  final AmapConsent consent;

  /// 真实路网路线来源。为空时退化为直线连接。
  final TripRouteService? routeService;

  final double height;

  /// 是否开放手势。全屏视图置 true，列表内的小地图必须为 false。
  final bool interactive;

  /// 点击地图。为空时不可点（例如已在全屏视图内）。
  final VoidCallback? onTap;

  @override
  State<TripRouteMap> createState() => _TripRouteMapState();
}

class _TripRouteMapState extends State<TripRouteMap> {
  /// 缓存的覆盖物。
  ///
  /// Marker/Polyline 在构造时各自生成 id，每帧新建会让插件把整批覆盖物
  /// 全删再全插，表现为闪烁。故按节点列表缓存，节点未变则复用同一批对象。
  Set<Marker> _markers = const {};
  Set<Polyline> _polylines = const {};
  List<TripStop>? _overlaySource;

  /// 真实路网返回的路径点。为空表示尚未取到或不可用，此时用直线。
  List<LatLng>? _roadPath;

  /// 路线服务失败的原因，用于向用户说明「为何是直线」。
  String? _routeFallbackReason;
  int _routeRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.consent.addListener(_onConsentChanged);
    if (widget.consent.agreed) _loadRoute();
  }

  @override
  void didUpdateWidget(TripRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.consent != widget.consent) {
      oldWidget.consent.removeListener(_onConsentChanged);
      widget.consent.addListener(_onConsentChanged);
    }
    // 行程换了或节点变了才重取：同一份数据重复请求既浪费配额也会闪。
    if (!_sameStops(oldWidget.plan.routeStops, widget.plan.routeStops)) {
      _routeRequestGeneration++;
      _roadPath = null;
      _routeFallbackReason = null;
      _overlaySource = null;
      if (widget.consent.agreed) _loadRoute();
    }
  }

  @override
  void dispose() {
    widget.consent.removeListener(_onConsentChanged);
    super.dispose();
  }

  void _onConsentChanged() {
    if (!mounted) return;
    if (widget.consent.agreed) {
      _loadRoute();
    } else {
      _routeRequestGeneration++;
      setState(() {
        _roadPath = null;
        _routeFallbackReason = null;
      });
    }
  }

  static bool _sameStops(List<TripStop> a, List<TripStop> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].title != b[i].title ||
          a[i].subtitle != b[i].subtitle ||
          a[i].latitude != b[i].latitude ||
          a[i].longitude != b[i].longitude) {
        return false;
      }
    }
    return true;
  }

  /// 取真实路网路线。失败时保持直线，不让整张地图失效。
  Future<void> _loadRoute() async {
    if (!widget.consent.agreed) return;
    final generation = ++_routeRequestGeneration;
    final service = widget.routeService;
    final stops = widget.plan.routeStops;
    if (service == null || stops.length < 2) return;

    try {
      final path = await service.resolveRoute(
        points: [
          for (final stop in stops)
            RoutePoint(latitude: stop.latitude!, longitude: stop.longitude!),
        ],
      );
      if (!mounted || generation != _routeRequestGeneration || path.isEmpty) {
        return;
      }
      setState(() {
        _roadPath = [
          for (final point in path) LatLng(point.latitude, point.longitude),
        ];
        _routeFallbackReason = null;
        _overlaySource = null;
      });
    } on TripRouteException catch (error) {
      // 路线服务不可用不该让地图失效：节点仍要显示，连线退化为直线并说明原因。
      if (!mounted || generation != _routeRequestGeneration) return;
      setState(() {
        _roadPath = null;
        _routeFallbackReason = error.message;
        _overlaySource = null;
      });
    }
  }

  void _rebuildOverlays(List<TripStop> stops, ColorScheme scheme) {
    _overlaySource = stops;

    _markers = {
      for (final (index, stop) in stops.indexed)
        Marker(
          position: LatLng(stop.latitude!, stop.longitude!),
          infoWindow: InfoWindow(
            // 按顺序编号：用户要看的是「先去哪后去哪」，只给点无法表达顺序。
            title: '${index + 1}. ${stop.title}',
            snippet: stop.subtitle,
          ),
        ),
    };

    final points =
        _roadPath ??
        [for (final stop in stops) LatLng(stop.latitude!, stop.longitude!)];
    _polylines = points.length < 2
        ? const {}
        : {
            Polyline(
              points: points,
              width: 6,
              color: scheme.primary,
              capType: CapType.round,
              joinType: JoinType.round,
            ),
          };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: SizedBox(
        height: widget.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          child: _buildBody(context, scheme),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    if (!widget.consent.agreed) {
      // 未同意时不渲染地图：插件在未声明合规前会白屏，一张无法解释的白块
      // 比一句说明更糟。
      return AmapConsentNotice(onAgree: widget.consent.agree);
    }

    final stops = widget.plan.routeStops;
    // 节点或路径变化后才重建覆盖物，避免每帧新建导致闪烁。
    if (_overlaySource == null || !_sameStops(_overlaySource!, stops)) {
      _rebuildOverlays(stops, scheme);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        AmapSurface(
          markers: _markers,
          polylines: _polylines,
          initialCameraPosition: cameraFor(stops),
          // 小地图不接手势：否则会吞掉行程页的纵向滚动。
          gesturesEnabled: widget.interactive,
          eagerGestures: widget.interactive,
          onMapCreated: (controller) => _fitBounds(controller, stops),
        ),
        if (widget.onTap case final onTap?)
          // 覆盖一层透明按钮承接点击：平台视图不参与 Flutter 的命中测试链，
          // 把 InkWell 包在外层收不到点击。
          Material(
            color: Colors.transparent,
            child: InkWell(onTap: onTap),
          ),
        if (_badgeText case final text?)
          Positioned(
            left: AppTokens.spaceSm,
            bottom: AppTokens.spaceSm,
            child: _RouteBadge(text: text),
          ),
      ],
    );
  }

  /// 地图角上要向用户说明的事，无需说明时为 null。
  ///
  /// 三种情形互斥，故收在一处按优先级判断：散在 build 里写成多路 else 分支时，
  /// 「单点」这一支很容易被漏掉而落到「直线连接」上。
  String? get _badgeText {
    // 单点行程没有任何连线，说「直线连接」是在描述一件不存在的事。
    if (!widget.plan.hasRouteLine) return '仅一个地点 · 再加一个即可看到路线';
    if (_routeFallbackReason case final reason?) return '直线连接 · $reason';
    // 路网未取到时退化为直线，要让用户知道这不是真实路径。
    if (_roadPath == null) return '直线连接';
    return null;
  }

  /// 把视野落在所有节点的中心，缩放按跨度估算。
  ///
  /// 初始视野必须一次给对：地图创建后再 moveCamera 会先闪一下默认视野。
  static CameraPosition cameraFor(List<TripStop> stops) {
    if (stops.isEmpty) return AmapSurface.initialCamera;
    final (minLat, maxLat, minLng, maxLng) = _boundsOf(stops);
    final span = math.max(maxLat - minLat, maxLng - minLng);
    return CameraPosition(
      target: LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
      zoom: TripRouteMapCamera.zoomForSpan(span),
    );
  }

  /// 返回 (minLat, maxLat, minLng, maxLng)。
  static (double, double, double, double) _boundsOf(List<TripStop> stops) {
    var minLat = stops.first.latitude!;
    var maxLat = minLat;
    var minLng = stops.first.longitude!;
    var maxLng = minLng;
    for (final stop in stops) {
      minLat = math.min(minLat, stop.latitude!);
      maxLat = math.max(maxLat, stop.latitude!);
      minLng = math.min(minLng, stop.longitude!);
      maxLng = math.max(maxLng, stop.longitude!);
    }
    return (minLat, maxLat, minLng, maxLng);
  }

  /// 创建后再按真实边界收敛一次，带上边距避免标记贴边被裁。
  void _fitBounds(AMapController controller, List<TripStop> stops) {
    if (stops.length < 2) return;
    final (minLat, maxLat, minLng, maxLng) = _boundsOf(stops);
    controller.moveCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        48,
      ),
    );
  }
}

/// 视野推导。
///
/// 单独成类而非留作 State 的私有方法：缩放公式是这块唯一有分支的纯逻辑，
/// 而 State 依赖平台视图无法在 Widget 测试里构建，抽出来才能直接单测。
abstract final class TripRouteMapCamera {
  /// 由经纬跨度估算缩放级别。
  ///
  /// 高德每降一级缩放，可视跨度约翻倍；以 360° 对应 z=1 反推即得下式。
  /// 上限 16：单点或极近的两点按公式会算出过大的级别，贴到楼栋级别反而
  /// 看不出空间关系。下限 3：再缩就看不出是哪片陆地了。
  static double zoomForSpan(double span) {
    if (span <= 0) return 14;
    final zoom = math.log(360 / span) / math.ln2;
    return zoom.clamp(3, 16).toDouble();
  }
}

/// 地图角上的说明标签。
class _RouteBadge extends StatelessWidget {
  const _RouteBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm,
          vertical: AppTokens.spaceXs,
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
