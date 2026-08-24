import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_route_map.dart';
import 'package:savorseek/features/trip/trip_route_service.dart';

/// 路线服务的错误归纳与视野推导。
///
/// 不覆盖地图渲染：`AMapWidget` 是平台视图，Widget 测试里没有原生侧可供绑定。
void main() {
  group('错误归纳', () {
    test('按 code 给出可展示的原因', () {
      String reason(String code) => EdgeFunctionRouteService.reasonFrom({
        'error': {'code': code, 'message': '服务端文案'},
      });

      expect(reason('unauthenticated'), '登录状态已失效');
      expect(reason('provider_key_missing'), '服务未配置');
      expect(reason('provider_key_rejected'), '服务未配置');
      expect(reason('provider_quota_exceeded'), '请求过于频繁');
      expect(reason('invalid_request'), '路线请求无效');
    });

    test('未知或缺失 code 时退回通用原因', () {
      expect(EdgeFunctionRouteService.reasonFrom(null), '路线服务暂不可用');
      expect(EdgeFunctionRouteService.reasonFrom('纯文本'), '路线服务暂不可用');
      expect(
        EdgeFunctionRouteService.reasonFrom({
          'error': {'code': 'x_unknown'},
        }),
        '路线服务暂不可用',
      );
    });
  });

  group('数值归一化', () {
    test('接受 int、double 与字符串', () {
      expect(EdgeFunctionRouteService.toDouble(38), 38.0);
      expect(EdgeFunctionRouteService.toDouble(38.9), 38.9);
      expect(EdgeFunctionRouteService.toDouble('38.9'), 38.9);
    });

    test('非数字返回 null', () {
      expect(EdgeFunctionRouteService.toDouble(null), isNull);
      expect(EdgeFunctionRouteService.toDouble('abc'), isNull);
      expect(EdgeFunctionRouteService.toDouble(const {}), isNull);
    });
  });

  group('视野推导', () {
    test('跨度为零时用固定级别', () {
      // 单点或完全重合的两点按公式会算出无穷大。
      expect(TripRouteMapCamera.zoomForSpan(0), 14);
    });

    test('跨度越大级别越小', () {
      final wide = TripRouteMapCamera.zoomForSpan(10);
      final narrow = TripRouteMapCamera.zoomForSpan(0.01);

      expect(wide, lessThan(narrow));
    });

    test('级别限制在 3..16', () {
      // 极小跨度贴到楼栋级别反而看不出空间关系；极大跨度不该缩到看不见陆地。
      expect(TripRouteMapCamera.zoomForSpan(0.000001), lessThanOrEqualTo(16));
      expect(TripRouteMapCamera.zoomForSpan(359), greaterThanOrEqualTo(3));
    });
  });
}
