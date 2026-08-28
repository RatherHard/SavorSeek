import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

/// 一条东京行程：19:00 当地 = UTC 10:00。
Map<String, dynamic> tokyoRow() => {
  'id': 'trip-tokyo',
  'title': '东京寻味',
  'timezone': 'Asia/Tokyo',
  'revision': 7,
  'updated_at': '2026-08-24T02:00:00+00:00',
  'trip_days': [
    {
      'id': 'day-1',
      'local_date': '2026-09-01',
      'trip_items': [
        {
          'id': 'item-1',
          'trip_day_id': 'day-1',
          'item_type': 'place_visit',
          'title': '寿司大',
          'planned_start_at': '2026-09-01T10:00:00+00:00',
          'planned_end_at': '2026-09-01T11:00:00+00:00',
          'time_slot': 'dinner',
          'position': 0,
          'status': 'planned',
        },
      ],
    },
  ],
};

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  group('跨时区行程按行程时区呈现', () {
    test('东京 19:00 不因设备时区而偏移', () {
      final plan = TripMapper.planFromRow(tokyoRow());
      final stop = plan.days.single.stops.single;

      // 设备时区为 UTC+8 时，按设备折算会得到 18:00——那是错的。
      // 数据模型文档第 33 行要求必须按 trips.timezone 转换。
      expect(plan.timezone, 'Asia/Tokyo');
      expect(stop.startAt.hour, 19);
      expect(stop.startAt.minute, 0);
      expect(stop.endAt.hour, 20);
      expect(stop.startAt.day, 1);
    });

    test('副标题用行程当地时间', () {
      final plan = TripMapper.planFromRow(tokyoRow());
      expect(plan.days.single.stops.single.subtitle, '晚餐 · 19:00–20:00');
    });

    test('revision 与时区一并带出，供改期作为 expected_revision', () {
      final plan = TripMapper.planFromRow(tokyoRow());
      expect(plan.revision, 7);
    });

    test('缺失 timezone 时退回库端默认值而非设备时区', () {
      final row = tokyoRow()..remove('timezone');
      final plan = TripMapper.planFromRow(row);

      // 退回 Asia/Shanghai（trips.timezone 的默认值）：UTC 10:00 即 18:00。
      expect(plan.timezone, 'Asia/Shanghai');
      expect(plan.days.single.stops.single.startAt.hour, 18);
    });

    test('无法识别的时区不致使整张行程打不开', () {
      final row = tokyoRow();
      row['timezone'] = 'Mars/Olympus';

      final plan = TripMapper.planFromRow(row);
      // 时间可能不准，但行程必须可读——这是刻意的降级。
      expect(plan.days.single.stops, hasLength(1));
      expect(plan.timezone, 'Mars/Olympus');
    });
  });

  group('改期所需字段', () {
    test('带出 trip_day_id 与 status', () {
      final stop = TripMapper.planFromRow(tokyoRow()).days.single.stops.single;

      expect(stop.tripDayId, 'day-1');
      expect(stop.status, TripItemStatus.planned);
      expect(stop.canReschedule, isTrue);
    });

    test('trip_days.id 带出，作为改期目标日标识', () {
      expect(TripMapper.planFromRow(tokyoRow()).days.single.id, 'day-1');
    });

    test('终态项不可改期', () {
      for (final status in ['completed', 'skipped']) {
        final row = tokyoRow();
        ((row['trip_days'] as List).first as Map)['trip_items'][0]['status'] =
            status;

        final stop = TripMapper.planFromRow(row).days.single.stops.single;
        expect(stop.status.isTerminal, isTrue, reason: status);
        expect(stop.canReschedule, isFalse, reason: status);
      }
    });

    test('planned 节点即使缺少 day id 仍可改期', () {
      final row = tokyoRow();
      ((row['trip_days'] as List).first as Map)['trip_items'][0].remove(
        'trip_day_id',
      );

      expect(
        TripMapper.planFromRow(row).days.single.stops.single.canReschedule,
        isTrue,
      );
    });

    test('未知状态退回 planned 而非抛错', () {
      final row = tokyoRow();
      ((row['trip_days'] as List).first as Map)['trip_items'][0]['status'] =
          'unknown';

      expect(
        TripMapper.planFromRow(row).days.single.stops.single.status,
        TripItemStatus.planned,
      );
    });
  });

  group('往返一致性', () {
    test('展示用的墙上时间折回 UTC 后与库中原值相同', () {
      final plan = TripMapper.planFromRow(tokyoRow());
      final stop = plan.days.single.stops.single;

      final restored = TripTimeZone.toInstant(
        timezone: plan.timezone,
        localDate: DateTime(
          stop.startAt.year,
          stop.startAt.month,
          stop.startAt.day,
        ),
        hour: stop.startAt.hour,
        minute: stop.startAt.minute,
      );

      // 改期正是这条路径：读出墙上时间 → 用户调整 → 折回 UTC 写入。
      expect(restored, DateTime.utc(2026, 9, 1, 10));
    });
  });
}
