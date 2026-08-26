import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

TripPlan buildPlan({String timezone = 'Asia/Shanghai'}) =>
    TripMapper.planFromRow({
      'id': 'trip-1',
      'title': '大连寻味',
      'timezone': timezone,
      'revision': 3,
      'status': 'draft',
      'trip_days': [
        {
          'id': 'day-1',
          'local_date': '2026-09-01',
          'trip_items': [
            {
              'id': 'item-planned',
              'trip_day_id': 'day-1',
              'item_type': 'place_visit',
              'title': '老长春烧烤',
              'planned_start_at': '2026-09-01T04:00:00+00:00',
              'planned_end_at': '2026-09-01T05:00:00+00:00',
              'time_slot': 'lunch',
              'position': 0,
              'status': 'planned',
            },
            {
              'id': 'item-second',
              'trip_day_id': 'day-1',
              'item_type': 'place_visit',
              'title': '另一家店',
              'planned_start_at': '2026-09-01T10:00:00+00:00',
              'planned_end_at': '2026-09-01T11:00:00+00:00',
              'time_slot': 'dinner',
              'position': 1,
              'status': 'planned',
            },
          ],
        },
      ],
    });

Widget wrap(FakeWritableRepository repository) => MaterialApp(
  home: TripDetailPage(repository: repository, tripId: 'trip-1'),
);

Future<void> openMenu(WidgetTester tester, int index) async {
  await tester.tap(find.byIcon(Icons.more_vert).at(index));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  testWidgets('待安排项菜单只有合并编辑与删除', (tester) async {
    await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
    await tester.pumpAndSettle();
    await openMenu(tester, 0);

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('改名称、备注与排期'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    expect(find.text('恢复'), findsNothing);
  });

  testWidgets('删除前二次确认且确认后调用 deleteTripItem', (tester) async {
    final repository = FakeWritableRepository(buildPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();
    await openMenu(tester, 0);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除这个行程项？'), findsOneWidget);
    expect(find.textContaining('无法恢复'), findsOneWidget);
    expect(repository.calls, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(repository.calls.single['op'], 'delete');
    expect(repository.calls.single['tripItemId'], 'item-planned');
  });

  testWidgets('完成行程底部按钮需要确认并调用 completeTrip', (tester) async {
    final repository = FakeWritableRepository(buildPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('完成行程'));
    await tester.pumpAndSettle();
    expect(find.text('完成这份行程？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '确认完成'));
    await tester.pumpAndSettle();
    expect(repository.calls.single['op'], 'completeTrip');
  });

  testWidgets('取消行程底部按钮需要确认并调用 cancelTrip', (tester) async {
    final repository = FakeWritableRepository(buildPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消行程'));
    await tester.pumpAndSettle();
    expect(find.text('取消这份行程？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '确认取消'));
    await tester.pumpAndSettle();
    expect(repository.calls.single['op'], 'cancelTrip');
  });

  testWidgets('整份行程删除说明级联清空', (tester) async {
    final repository = FakeWritableRepository(buildPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('行程操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除行程'));
    await tester.pumpAndSettle();

    expect(find.text('删除整份行程？'), findsOneWidget);
    expect(find.textContaining('级联清空'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
    await tester.pumpAndSettle();
    expect(repository.calls.single['op'], 'deleteTrip');
  });

  testWidgets('同时区行程不标注时区', (tester) async {
    await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
    await tester.pumpAndSettle();
    expect(find.textContaining('时间按'), findsNothing);
  });

  testWidgets('跨时区行程标注时间基准与时差', (tester) async {
    await tester.pumpWidget(
      wrap(FakeWritableRepository(buildPlan(timezone: 'Asia/Tokyo'))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('时间按 Asia/Tokyo 显示'), findsOneWidget);
    expect(find.textContaining('相差 +1 小时'), findsOneWidget);
  });

  testWidgets('不再提供修改行程时区入口', (tester) async {
    await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('行程操作'));
    await tester.pumpAndSettle();
    expect(find.text('更改行程时区'), findsNothing);
  });
}
