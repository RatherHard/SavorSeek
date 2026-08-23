import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_repository.dart';

void main() {
  group('PlaceSnapshot 序列化', () {
    test('带坐标时输出全部字段', () {
      // 库端 trigger 逐项校验，字段名与取值必须严格匹配。
      final json = const PlaceSnapshot(
        name: '本帮菜馆',
        latitude: 31.2304,
        longitude: 121.4737,
      ).toJson();

      expect(json, {
        'schema_version': 1,
        'name': '本帮菜馆',
        'latitude': 31.2304,
        'longitude': 121.4737,
        'coordinate_system': 'gcj02',
      });
    });

    test('无坐标时整组坐标字段一并省略', () {
      // trigger 要求经纬度同时存在或同时缺失，只带 coordinate_system 会被拒。
      final json = const PlaceSnapshot(name: '待补充坐标的小店').toJson();

      expect(json, {'schema_version': 1, 'name': '待补充坐标的小店'});
    });

    test('坐标系可切换为 wgs84', () {
      final json = const PlaceSnapshot(
        name: '海外小馆',
        latitude: 35.6762,
        longitude: 139.6503,
        coordinateSystem: PlaceCoordinateSystem.wgs84,
      ).toJson();

      expect(json['coordinate_system'], 'wgs84');
    });

    test('只给一个坐标分量会在构造期失败', () {
      expect(
        () => PlaceSnapshot(name: '缺经度', latitude: 31.2304),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
