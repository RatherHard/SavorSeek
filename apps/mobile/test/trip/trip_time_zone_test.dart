import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  group('isSupported', () {
    test('接受 IANA 标识', () {
      expect(TripTimeZone.isSupported('Asia/Shanghai'), isTrue);
      expect(TripTimeZone.isSupported('Asia/Tokyo'), isTrue);
      expect(TripTimeZone.isSupported('Europe/Paris'), isTrue);
      expect(TripTimeZone.isSupported('America/New_York'), isTrue);
      expect(TripTimeZone.isSupported('UTC'), isTrue);
    });

    test('拒绝固定偏移写法与无效标识', () {
      // 数据模型文档第 34 行：不得只保存 UTC+8 一类固定偏移。
      expect(TripTimeZone.isSupported('UTC+8'), isFalse);
      expect(TripTimeZone.isSupported('北京时间'), isFalse);
      expect(TripTimeZone.isSupported(''), isFalse);
    });
  });

  group('toInstant', () {
    test('中国无夏令时，恒按 +08:00 折算', () {
      // 一月与七月结果一致，说明没有夏令时。
      expect(
        TripTimeZone.toInstant(
          timezone: 'Asia/Shanghai',
          localDate: DateTime(2026, 1, 15),
          hour: 12,
        ),
        DateTime.utc(2026, 1, 15, 4),
      );
      expect(
        TripTimeZone.toInstant(
          timezone: 'Asia/Shanghai',
          localDate: DateTime(2026, 7, 15),
          hour: 12,
        ),
        DateTime.utc(2026, 7, 15, 4),
      );
    });

    test('东京 +09:00', () {
      expect(
        TripTimeZone.toInstant(
          timezone: 'Asia/Tokyo',
          localDate: DateTime(2026, 9, 1),
          hour: 19,
          minute: 30,
        ),
        DateTime.utc(2026, 9, 1, 10, 30),
      );
    });

    test('夏令时地区在冬夏两季偏移不同（固定偏移表会算错）', () {
      // 巴黎冬季 +01:00、夏季 +02:00。这正是不能用固定偏移的原因。
      final winter = TripTimeZone.toInstant(
        timezone: 'Europe/Paris',
        localDate: DateTime(2026, 1, 15),
        hour: 12,
      );
      final summer = TripTimeZone.toInstant(
        timezone: 'Europe/Paris',
        localDate: DateTime(2026, 7, 15),
        hour: 12,
      );

      expect(winter, DateTime.utc(2026, 1, 15, 11));
      expect(summer, DateTime.utc(2026, 7, 15, 10));
    });

    test('分钟参与折算', () {
      expect(
        TripTimeZone.toInstant(
          timezone: 'Asia/Shanghai',
          localDate: DateTime(2026, 9, 1),
          hour: 19,
          minute: 45,
        ),
        DateTime.utc(2026, 9, 1, 11, 45),
      );
    });

    test('未知时区抛 TripTimeZoneException', () {
      expect(
        () => TripTimeZone.toInstant(
          timezone: 'Mars/Olympus',
          localDate: DateTime(2026, 9, 1),
          hour: 12,
        ),
        throwsA(isA<TripTimeZoneException>()),
      );
    });
  });

  group('toWallClock', () {
    test('与 toInstant 互为逆运算', () {
      for (final zone in ['Asia/Shanghai', 'Asia/Tokyo', 'Europe/Paris']) {
        for (final month in [1, 7]) {
          final date = DateTime(2026, month, 15);
          final instant = TripTimeZone.toInstant(
            timezone: zone,
            localDate: date,
            hour: 19,
            minute: 30,
          );
          final wall = TripTimeZone.toWallClock(
            timezone: zone,
            instant: instant,
          );

          expect(wall.year, 2026, reason: '$zone $month 月');
          expect(wall.month, month, reason: '$zone $month 月');
          expect(wall.day, 15, reason: '$zone $month 月');
          expect(wall.hour, 19, reason: '$zone $month 月');
          expect(wall.minute, 30, reason: '$zone $month 月');
        }
      }
    });

    test('折算结果落在与所选日期相同的当地日期上', () {
      // 库端据此比对 trip_day.local_date，跨日错误会被 trigger 拒绝。
      for (final hour in [0, 1, 12, 23]) {
        final date = DateTime(2026, 9, 1);
        final instant = TripTimeZone.toInstant(
          timezone: 'Asia/Tokyo',
          localDate: date,
          hour: hour,
        );
        final wall = TripTimeZone.toWallClock(
          timezone: 'Asia/Tokyo',
          instant: instant,
        );
        expect(wall.day, 1, reason: '$hour 时折算后落到了 ${wall.day} 日');
        expect(wall.hour, hour);
      }
    });
  });

  group('offsetAt', () {
    test('按时刻返回偏移，夏令时前后不同', () {
      expect(
        TripTimeZone.offsetAt(
          timezone: 'Asia/Shanghai',
          instant: DateTime.utc(2026, 7, 1),
        ),
        const Duration(hours: 8),
      );
      expect(
        TripTimeZone.offsetAt(
          timezone: 'Europe/Paris',
          instant: DateTime.utc(2026, 1, 15),
        ),
        const Duration(hours: 1),
      );
      expect(
        TripTimeZone.offsetAt(
          timezone: 'Europe/Paris',
          instant: DateTime.utc(2026, 7, 15),
        ),
        const Duration(hours: 2),
      );
    });
  });

  group('formatOffsetDifference', () {
    test('时差表述带符号或标明无时差', () {
      // 不硬编码期望值：结果取决于运行测试的设备时区。
      for (final zone in ['Asia/Shanghai', 'Asia/Tokyo', 'Europe/Paris']) {
        final label = TripTimeZone.formatOffsetDifference(
          timezone: zone,
          instant: DateTime.utc(2026, 9, 1, 4),
        );
        expect(
          label,
          anyOf('无时差', matches(r'^[+-]\d+ 小时( \d+ 分)?$')),
          reason: zone,
        );
      }
    });

    test('同偏移时区之间判定为无时差', () {
      // Asia/Macau 与 Asia/Shanghai 名称不同但恒为 +08:00。
      final instant = DateTime.utc(2026, 9, 1, 4);
      expect(
        TripTimeZone.offsetAt(timezone: 'Asia/Macau', instant: instant),
        TripTimeZone.offsetAt(timezone: 'Asia/Shanghai', instant: instant),
      );
    });
  });
}
