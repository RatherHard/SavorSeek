import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';

/// 节点坐标的读取与路线可用性的派生。
void main() {
  Map<String, dynamic> item({
    required String id,
    Object? snapshot,
    String status = 'planned',
    int position = 0,
  }) {
    return {
      'id': id,
      'trip_day_id': 'day-1',
      'item_type': 'place_visit',
      'title': '店 $id',
      'planned_start_at': '2026-09-01T04:00:00+00:00',
      'planned_end_at': '2026-09-01T05:00:00+00:00',
      'time_slot': 'lunch',
      'position': position,
      'status': status,
      'place_snapshot': snapshot,
    };
  }

  Map<String, dynamic> plan(List<Map<String, dynamic>> items) => {
    'id': 'trip-1',
    'title': '大连寻味',
    'timezone': 'Asia/Shanghai',
    'revision': 1,
    'trip_days': [
      {'id': 'day-1', 'local_date': '2026-09-01', 'trip_items': items},
    ],
  };

  const snapshotA = {
    'schema_version': 1,
    'name': '海鲜面馆',
    'latitude': 38.914003,
    'longitude': 121.614682,
    'coordinate_system': 'gcj02',
  };
  const snapshotB = {
    'schema_version': 1,
    'name': '烧烤店',
    'latitude': 38.92,
    'longitude': 121.62,
    'coordinate_system': 'gcj02',
  };

  group('坐标解析', () {
    test('从 place_snapshot 读出经纬度', () {
      final stop = TripMapper.stopFromRow(item(id: '1', snapshot: snapshotA));

      expect(stop.latitude, 38.914003);
      expect(stop.longitude, 121.614682);
      expect(stop.hasCoordinates, isTrue);
    });

    test('缺少快照时无坐标', () {
      final stop = TripMapper.stopFromRow(item(id: '1'));

      expect(stop.hasCoordinates, isFalse);
    });

    test('只有一个坐标分量时视为无坐标', () {
      // 库端 trigger 要求成对出现，但快照是 jsonb，历史数据可能绕过校验。
      final stop = TripMapper.stopFromRow(
        item(
          id: '1',
          snapshot: const {'schema_version': 1, 'name': '店', 'latitude': 38.9},
        ),
      );

      expect(stop.hasCoordinates, isFalse);
    });

    test('越界坐标视为无坐标', () {
      // 越界值会把地图视野拉到世界另一端，宁可不画。
      final stop = TripMapper.stopFromRow(
        item(
          id: '1',
          snapshot: const {
            'schema_version': 1,
            'name': '店',
            'latitude': 200.0,
            'longitude': 121.6,
          },
        ),
      );

      expect(stop.hasCoordinates, isFalse);
    });

    test('字符串形式的坐标也能解析', () {
      // jsonb 的数字可能读回字符串。
      final stop = TripMapper.stopFromRow(
        item(
          id: '1',
          snapshot: const {
            'schema_version': 1,
            'name': '店',
            'latitude': '38.9',
            'longitude': '121.6',
          },
        ),
      );

      expect(stop.latitude, 38.9);
      expect(stop.longitude, 121.6);
    });
  });

  group('路线可用性', () {
    test('两个以上可定位节点时地图可用', () {
      final result = TripMapper.planFromRow(
        plan([
          item(id: '1', snapshot: snapshotA),
          item(id: '2', snapshot: snapshotB, position: 1),
        ]),
      );

      expect(result.mapState, TripMapState.available);
      expect(result.hasRoute, isTrue);
      expect(result.routeStops.length, 2);
    });

    test('只有一个可定位节点时地图不可用', () {
      final result = TripMapper.planFromRow(
        plan([item(id: '1', snapshot: snapshotA), item(id: '2', position: 1)]),
      );

      expect(result.mapState, TripMapState.unavailable);
      expect(result.hasRoute, isFalse);
    });

    test('已取消的节点不进入路线', () {
      // 取消的项不在计划路线上，画进去会让路线绕行到一个已决定不去的点。
      final result = TripMapper.planFromRow(
        plan([
          item(id: '1', snapshot: snapshotA),
          item(id: '2', snapshot: snapshotB, position: 1, status: 'cancelled'),
        ]),
      );

      expect(result.routeStops.length, 1);
      expect(result.hasRoute, isFalse);
    });

    test('路线节点保持时间顺序', () {
      final result = TripMapper.planFromRow(
        plan([
          item(id: '1', snapshot: snapshotA),
          item(id: '2', snapshot: snapshotB, position: 1),
        ]),
      );

      expect(result.routeStops.map((stop) => stop.id).toList(), ['1', '2']);
    });
  });
}
