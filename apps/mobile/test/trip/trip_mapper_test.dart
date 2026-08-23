import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';

/// 构造一条合成的 trip_items 行，字段名与 itinerary_schema.sql 一致。
Map<String, dynamic> itemRow({
  String id = 'aaaaaaaa-0000-4000-8000-000000000001',
  String title = '本帮菜午餐',
  String timeSlot = 'lunch',
  String itemType = 'place_visit',
  String startAt = '2026-08-22T04:00:00+00:00',
  String endAt = '2026-08-22T05:30:00+00:00',
  int position = 0,
  String? notes,
  bool placeLocked = false,
  bool timeLocked = false,
  bool orderLocked = false,
  String status = 'planned',
}) {
  return {
    'id': id,
    'title': title,
    'time_slot': timeSlot,
    'item_type': itemType,
    'planned_start_at': startAt,
    'planned_end_at': endAt,
    'position': position,
    'notes': notes,
    'status': status,
    'is_place_locked': placeLocked,
    'is_time_locked': timeLocked,
    'is_order_locked': orderLocked,
  };
}

void main() {
  group('枚举映射', () {
    test('每个 time_slot 字面值都能双向还原', () {
      for (final type in TripStopType.values) {
        expect(TripMapper.stopTypeFromWire(type.wireName), type);
      }
    });

    test('未知 time_slot 退回 flexible 而不是抛错', () {
      // 库端若先行扩展枚举，一个新时段不应让整张行程无法显示。
      expect(TripMapper.stopTypeFromWire('brunch'), TripStopType.flexible);
      expect(TripMapper.stopTypeFromWire(null), TripStopType.flexible);
    });

    test('item_type 映射覆盖地点与休息两种', () {
      expect(
        TripMapper.itemTypeFromWire('place_visit'),
        TripItemType.placeVisit,
      );
      expect(TripMapper.itemTypeFromWire('break'), TripItemType.break_);
      expect(TripMapper.itemTypeFromWire(null), TripItemType.placeVisit);
    });
  });

  group('锁定标志合并', () {
    test('三者全假时未锁定', () {
      expect(TripMapper.isLockedFrom(itemRow()), isFalse);
    });

    test('任一为真即视为锁定', () {
      expect(TripMapper.isLockedFrom(itemRow(placeLocked: true)), isTrue);
      expect(TripMapper.isLockedFrom(itemRow(timeLocked: true)), isTrue);
      expect(TripMapper.isLockedFrom(itemRow(orderLocked: true)), isTrue);
    });

    test('字段缺失按未锁定处理', () {
      expect(TripMapper.isLockedFrom(const {}), isFalse);
    });
  });

  group('时区处理', () {
    test('timestamptz 转为设备本地时间', () {
      final stop = TripMapper.stopFromRow(
        itemRow(
          startAt: '2026-08-22T04:00:00+00:00',
          endAt: '2026-08-22T05:30:00+00:00',
        ),
      );

      // 不转换会让 UI 直接显示 UTC 时刻，这是本次对接最易漏掉的一处。
      expect(stop.startAt.isUtc, isFalse);
      expect(stop.startAt, DateTime.utc(2026, 8, 22, 4).toLocal());
      expect(stop.endAt, DateTime.utc(2026, 8, 22, 5, 30).toLocal());
    });

    test('带偏移的字符串按同一时刻解释', () {
      final withOffset = TripMapper.stopFromRow(
        itemRow(
          startAt: '2026-08-22T12:00:00+08:00',
          endAt: '2026-08-22T13:00:00+08:00',
        ),
      );

      expect(withOffset.startAt, DateTime.utc(2026, 8, 22, 4).toLocal());
    });
  });

  group('派生字段', () {
    test('副标题由时段与起止时间拼装', () {
      final stop = TripMapper.stopFromRow(
        itemRow(
          timeSlot: 'afternoon_tea',
          startAt: DateTime(2026, 8, 22, 15).toUtc().toIso8601String(),
          endAt: DateTime(2026, 8, 22, 16, 30).toUtc().toIso8601String(),
        ),
      );

      expect(stop.subtitle, '下午茶 · 15:00–16:30');
    });

    test('日期标签生成周几与月日', () {
      // 2026-08-22 是周六。
      expect(TripMapper.dayLabel(DateTime(2026, 8, 22)), '周六 · 8 月 22 日');
      expect(TripMapper.dayLabel(DateTime(2026, 8, 24)), '周一 · 8 月 24 日');
    });

    test('destination 由地点项标题推导，休息项不计入', () {
      final plan = TripMapper.planFromRow({
        'id': 'bbbbbbbb-0000-4000-8000-000000000002',
        'title': '上海一日寻味',
        'updated_at': '2026-08-21T10:00:00+00:00',
        'trip_days': [
          {
            'local_date': '2026-08-22',
            'trip_items': [
              itemRow(title: '小笼包'),
              itemRow(
                id: 'aaaaaaaa-0000-4000-8000-000000000003',
                title: '午休',
                itemType: 'break',
                position: 1,
              ),
              itemRow(
                id: 'aaaaaaaa-0000-4000-8000-000000000004',
                title: '生煎',
                position: 2,
              ),
            ],
          },
        ],
      });

      expect(plan.destination, '小笼包 · 生煎');
      expect(plan.days.single.stops.length, 3);
      expect(plan.updatedAt, isNotNull);
    });

    test('无行程日时 destination 为空串', () {
      final plan = TripMapper.planFromRow({
        'id': 'bbbbbbbb-0000-4000-8000-000000000005',
        'title': '空行程',
        'trip_days': const [],
      });

      expect(plan.destination, '');
      expect(plan.days, isEmpty);
      expect(plan.updatedAt, isNull);
    });
  });

  test('空白备注归一为 null，避免渲染空段落', () {
    expect(TripMapper.stopFromRow(itemRow(notes: '   ')).note, isNull);
    expect(TripMapper.stopFromRow(itemRow(notes: ' 先取号 ')).note, '先取号');
  });
}
