import 'package:amap_map/amap_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/app/config/amap_config.dart';

/// 高德地图显示区域。
///
/// 只负责「把瓦片显示出来、渲染传入的覆盖物并支持手势」，不承载业务逻辑：
/// 标记由上层构造后传入，本组件不知道地点从哪来、点击后该做什么。聚合与筛选
/// 同样留给上层。
class AmapSurface extends StatefulWidget {
  const AmapSurface({
    super.key,
    this.onMapCreated,
    this.markers = const <Marker>{},
    this.onMapTap,
  });

  final void Function(AMapController controller)? onMapCreated;

  /// 要渲染的标记集合。插件按 marker id 做增量更新，重复传入同一集合不会闪烁。
  final Set<Marker> markers;

  /// 点击地图空白处。用于收起地点详情面板。
  final void Function(LatLng position)? onMapTap;

  /// 默认视野中心（大连），在定位能力接入前作为回退中心点。
  static const CameraPosition initialCamera = CameraPosition(
    target: LatLng(38.914003, 121.614682),
    zoom: 13,
  );

  @override
  State<AmapSurface> createState() => _AmapSurfaceState();
}

class _AmapSurfaceState extends State<AmapSurface> {
  @override
  void initState() {
    super.initState();
    // 合规声明须在地图组件构建前设置：此处三项均为 true 的前提是调用方
    // 已通过同意闸门（见 AmapConsent），未同意时不会渲染本组件。
    AMapInitializer.updatePrivacyAgree(
      const AMapPrivacyStatement(
        hasContains: true,
        hasShow: true,
        hasAgree: true,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // init 需要 context 做图片资源的屏幕密度适配。
    //
    // Android 的 Key 由 manifest 提供，此处 androidKey 通常为 null，插件会跳过
    // setApiKey，保留原生侧已读取的值。不可传空字符串：插件的 checkApiKey 只判
    // 空引用不判空串，传 '' 会以空 Key 覆盖 manifest 中的有效值。
    AMapInitializer.init(
      context,
      apiKey: AMapApiKey(
        androidKey: AmapConfig.androidKey,
        iosKey: AmapConfig.iosKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AMapWidget(
      initialCameraPosition: AmapSurface.initialCamera,
      onMapCreated: widget.onMapCreated,
      markers: widget.markers,
      onTap: widget.onMapTap,
      // 单指拖拽与双指缩放为本阶段的硬性要求。
      scrollGesturesEnabled: true,
      zoomGesturesEnabled: true,
      // 旋转与倾斜暂不开放：地图需保持正北朝上，避免用户误操作后
      // 难以恢复方向，也便于后续路线视图与时间表保持一致的方位参照。
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      scaleEnabled: true,
      compassEnabled: false,
      // 地图占据除底部指令栏外的全部空间，手势不应被父级滚动组件截获。
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
      },
    );
  }
}
