import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/schedule_picker_sheet.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

TripSchedulingContext buildTrip({int dayCount = 3}) {
  return TripSchedulingContext(
    tripId: 'trip-1',
    revision: 1,
    timezone: 'Asia/Shanghai',
    days: List.generate(
      dayCount,
      (index) =>
          TripDayRef(id: 'day-$index', localDate: DateTime(2026, 9, 1 + index)),
    ),
  );
}

Widget wrap(
  TripSchedulingContext trip,
  void Function(ScheduleSelection?) onResult,
) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => onResult(
            await showSchedulePickerSheet(
              context,
              placeName: '老长春烧烤',
              trip: trip,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('时段由时间推导', () {
    test('各时间点落入对应时段', () {
      expect(timeSlotForHour(7), TripStopType.breakfast);
      expect(timeSlotForHour(10), TripStopType.morning);
      expect(timeSlotForHour(12), TripStopType.lunch);
      expect(timeSlotForHour(15), TripStopType.afternoonTea);
      expect(timeSlotForHour(19), TripStopType.dinner);
      expect(timeSlotForHour(22), TripStopType.lateNight);
    });

    test('深夜与清晨归为灵活安排，不硬塞进餐段', () {
      expect(timeSlotForHour(3), TripStopType.flexible);
      expect(timeSlotForHour(0), TripStopType.flexible);
      expect(timeSlotForHour(5), TripStopType.flexible);
    });

    test('边界值归属明确', () {
      // 11:00 起算午餐，14:00 起算下午茶。
      expect(timeSlotForHour(11), TripStopType.lunch);
      expect(timeSlotForHour(13), TripStopType.lunch);
      expect(timeSlotForHour(14), TripStopType.afternoonTea);
      expect(timeSlotForHour(17), TripStopType.dinner);
      expect(timeSlotForHour(21), TripStopType.lateNight);
    });

    test('推导出的时段取值都在库端 check 约束内', () {
      const allowed = {
        'breakfast',
        'morning',
        'lunch',
        'afternoon_tea',
        'dinner',
        'late_night',
        'flexible',
      };
      for (var hour = 0; hour < 24; hour++) {
        expect(allowed, contains(timeSlotForHour(hour).wireName));
      }
    });
  });

  group('格式化', () {
    test('日期带星期', () {
      // 2026-09-01 是周二。
      expect(formatLocalDate(DateTime(2026, 9, 1)), '2026-09-01（周二）');
    });

    test('时间恒为 24 小时制两位补零', () {
      expect(formatWallClock(9, 5), '09:05');
      expect(formatWallClock(19, 30), '19:30');
      expect(formatWallClock(0, 0), '00:00');
    });

    test('时长按小时与分钟组合', () {
      expect(formatDuration(const Duration(minutes: 30)), '30 分钟');
      expect(formatDuration(const Duration(minutes: 60)), '1 小时');
      expect(formatDuration(const Duration(minutes: 90)), '1 小时 30 分');
      expect(formatDuration(const Duration(minutes: 180)), '3 小时');
    });
  });

  group('showSchedulePickerSheet', () {
    testWidgets('默认取首日 12:00、时长 1 小时', (tester) async {
      ScheduleSelection? selection;
      await tester.pumpWidget(wrap(buildTrip(), (v) => selection = v));
      await openSheet(tester);

      expect(find.text('2026-09-01（周二）'), findsOneWidget);
      expect(find.text('12:00'), findsOneWidget);

      await tester.tap(find.text('加入行程'));
      await tester.pumpAndSettle();

      expect(selection, isNotNull);
      expect(selection!.day.id, 'day-0');
      expect(selection!.hour, 12);
      expect(selection!.minute, 0);
      expect(selection!.duration, const Duration(hours: 1));
      // 12:00 应推导为午餐。
      expect(selection!.timeSlot, TripStopType.lunch);
    });

    testWidgets('展示推导出的时段与时间区间', (tester) async {
      await tester.pumpWidget(wrap(buildTrip(), (_) {}));
      await openSheet(tester);

      expect(find.textContaining('将排入「午餐」时段，12:00–13:00'), findsOneWidget);
    });

    testWidgets('改时长后区间与时段随之更新', (tester) async {
      ScheduleSelection? selection;
      await tester.pumpWidget(wrap(buildTrip(), (v) => selection = v));
      await openSheet(tester);

      await tester.tap(find.text('3 小时'));
      await tester.pumpAndSettle();

      expect(find.textContaining('12:00–15:00'), findsOneWidget);

      await tester.tap(find.text('加入行程'));
      await tester.pumpAndSettle();
      expect(selection!.duration, const Duration(hours: 3));
    });

    testWidgets('单日行程禁用日期选择并说明原因', (tester) async {
      await tester.pumpWidget(wrap(buildTrip(dayCount: 1), (_) {}));
      await openSheet(tester);

      // 只有一个可选项时，弹一个选择器是徒劳的。
      expect(find.text('该行程只有一天'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('多日行程可选日期', (tester) async {
      await tester.pumpWidget(wrap(buildTrip(), (_) {}));
      await openSheet(tester);

      expect(find.text('该行程只有一天'), findsNothing);
      // 日期与时间两行都可点。
      expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    });

    testWidgets('取消返回 null', (tester) async {
      ScheduleSelection? selection;
      var count = 0;
      await tester.pumpWidget(
        wrap(buildTrip(), (v) {
          selection = v;
          count++;
        }),
      );
      await openSheet(tester);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(count, 1);
      expect(selection, isNull);
    });
  });
}
