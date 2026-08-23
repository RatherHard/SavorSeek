import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/trip/add_place_to_trip.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

Place buildPlace({
  double? latitude = 38.914003,
  double? longitude = 121.614682,
}) {
  return Place(
    id: 'place-1',
    name: '老长春烧烤',
    category: '餐饮服务;中餐厅;烧烤',
    address: '中山区某路 1 号',
    latitude: latitude,
    longitude: longitude,
    fetchedAt: DateTime(2026, 8, 23, 12),
  );
}

void main() {
  group('buildSnapshot', () {
    test('产出满足库端约束的快照', () {
      final json = buildSnapshot(buildPlace()).toJson();

      // 库端 trigger 逐项校验这四项（itinerary_schema.sql:243-259）。
      expect(json['schema_version'], 1);
      expect(json['name'], '老长春烧烤');
      expect(json['latitude'], 38.914003);
      expect(json['longitude'], 121.614682);
      expect(json['coordinate_system'], 'gcj02');
    });

    test('无坐标时不写入经纬度与坐标系', () {
      final json = buildSnapshot(
        buildPlace(latitude: null, longitude: null),
      ).toJson();

      // 「经纬度必须成对出现或同时省略」——只带 coordinate_system 会被拒。
      expect(json.containsKey('latitude'), isFalse);
      expect(json.containsKey('longitude'), isFalse);
      expect(json.containsKey('coordinate_system'), isFalse);
      expect(json['name'], '老长春烧烤');
    });
  });

  group('resolveInstant', () {
    test('按行程时区折算，而非设备本地时区', () {
      final start = resolveInstant(
        localDate: DateTime(2026, 9, 1),
        timezone: 'Asia/Shanghai',
        hour: 12,
      );

      // +08:00 的 12:00 即 UTC 04:00。库端会把该时刻折回 Asia/Shanghai 再比对
      // trip_day.local_date，必须仍落在 9 月 1 日。
      expect(start.isUtc, isTrue);
      expect(start, DateTime.utc(2026, 9, 1, 4));
    });

    test('折算结果在行程时区下仍是同一天（含边界小时）', () {
      for (final hour in [0, 8, 12, 23]) {
        final start = resolveInstant(
          localDate: DateTime(2026, 9, 1),
          timezone: 'Asia/Shanghai',
          hour: hour,
        );
        final wallClock = start.add(const Duration(hours: 8));
        expect(wallClock.day, 1, reason: '$hour 时折算后落到了 ${wallClock.day} 日');
        expect(wallClock.hour, hour);
      }
    });

    test('UTC 行程不做偏移', () {
      final start = resolveInstant(
        localDate: DateTime(2026, 9, 1),
        timezone: 'UTC',
        hour: 12,
      );

      expect(start, DateTime.utc(2026, 9, 1, 12));
    });

    test('分钟参与折算，不被丢弃', () {
      // 时分选择的意义就在于此：只取小时会让 19:30 静默变成 19:00。
      final start = resolveInstant(
        localDate: DateTime(2026, 9, 1),
        timezone: 'Asia/Shanghai',
        hour: 19,
        minute: 30,
      );

      expect(start, DateTime.utc(2026, 9, 1, 11, 30));
      final wallClock = start.add(const Duration(hours: 8));
      expect(wallClock.hour, 19);
      expect(wallClock.minute, 30);
      expect(wallClock.day, 1);
    });

    test('跨日边界：23:30 起算仍归属所选那天', () {
      final start = resolveInstant(
        localDate: DateTime(2026, 9, 1),
        timezone: 'Asia/Shanghai',
        hour: 23,
        minute: 30,
      );

      expect(start, DateTime.utc(2026, 9, 1, 15, 30));
      final wallClock = start.add(const Duration(hours: 8));
      expect(wallClock.day, 1);
      expect(wallClock.hour, 23);
      expect(wallClock.minute, 30);
    });

    test('未知时区抛错而非静默按 UTC 处理', () {
      // 静默降级会写出差一天的数据，且要等库端 23514 才暴露。
      expect(
        () => resolveInstant(
          localDate: DateTime(2026, 9, 1),
          timezone: 'America/New_York',
          hour: 12,
        ),
        throwsA(isA<TripRepositoryException>()),
      );
    });
  });
}
