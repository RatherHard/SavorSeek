import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/timezone_picker_sheet.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

/// 一日行程：一个待安排项 + 一个已取消项。
TripPlan buildPlan({String timezone = 'Asia/Shanghai'}) =>
    TripMapper.planFromRow({
      'id': 'trip-1',
      'title': '大连寻味',
      'timezone': timezone,
      'revision': 3,
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
              'id': 'item-cancelled',
              'trip_day_id': 'day-1',
              'item_type': 'place_visit',
              'title': '已取消的店',
              'planned_start_at': '2026-09-01T10:00:00+00:00',
              'planned_end_at': '2026-09-01T11:00:00+00:00',
              'time_slot': 'dinner',
              'position': 1,
              'status': 'cancelled',
            },
          ],
        },
      ],
    });

Widget wrap(FakeWritableRepository repository) => MaterialApp(
  home: TripDetailPage(repository: repository, tripId: 'trip-1'),
);

/// 打开第 [index] 个行程项的菜单。
Future<void> openMenu(WidgetTester tester, int index) async {
  await tester.tap(find.byIcon(Icons.more_vert).at(index));
  await tester.pumpAndSettle();
}

/// 打开行程级操作菜单并选择「更改行程时区」。
///
/// 行程级操作聚合在一个菜单里，时区入口因此是两步：先展开菜单再点条目。
Future<void> openTimezonePicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('行程操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('更改行程时区'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  group('已取消的项仍可见且可恢复', () {
    testWidgets('取消的项展示在列表中并标注状态', (tester) async {
      await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
      await tester.pumpAndSettle();

      // 用户决策：软删除后 UI 仍可见——过滤掉就没有恢复入口了。
      expect(find.text('已取消的店'), findsOneWidget);
      expect(find.text('已取消'), findsOneWidget);
    });

    testWidgets('待安排项的菜单给出改期与取消，不给恢复', (tester) async {
      await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
      await tester.pumpAndSettle();
      await openMenu(tester, 0);

      expect(find.text('改期'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('恢复'), findsNothing);
    });

    testWidgets('已取消项的菜单给出恢复，不给改期', (tester) async {
      await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
      await tester.pumpAndSettle();
      await openMenu(tester, 1);

      expect(find.text('恢复'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      // 已取消的项改期没有意义，库端也会拒绝。
      expect(find.text('改期'), findsNothing);
    });
  });

  group('取消与恢复', () {
    testWidgets('取消调用 cancelTripItem', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openMenu(tester, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(repository.calls, hasLength(1));
      expect(repository.calls.single['op'], 'cancel');
      expect(repository.calls.single['tripItemId'], 'item-planned');
      // 提示条上直接给「撤销」，不再让用户回列表里自己找那一项选恢复。
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
    });

    testWidgets('恢复调用 restoreTripItem', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openMenu(tester, 1);
      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();

      expect(repository.calls.single['op'], 'restore');
      expect(repository.calls.single['tripItemId'], 'item-cancelled');
    });
  });

  group('硬删除', () {
    testWidgets('删除前必须二次确认，且说明与取消的区别', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openMenu(tester, 0);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('删除这个行程项？'), findsOneWidget);
      // 不可恢复是关键信息，且要给出「取消」这条更温和的替代路径。
      expect(find.textContaining('无法恢复'), findsOneWidget);
      expect(find.textContaining('改用「取消」'), findsOneWidget);
      // 尚未确认，不应产生写入。
      expect(repository.calls, isEmpty);
    });

    testWidgets('确认后调用 deleteTripItem', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openMenu(tester, 0);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      // 对话框里的「删除」按钮。
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(repository.calls.single['op'], 'delete');
      expect(repository.calls.single['tripItemId'], 'item-planned');
    });

    testWidgets('放弃确认不产生写入', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openMenu(tester, 0);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();

      expect(repository.calls, isEmpty);
    });
  });

  group('更改行程时区', () {
    testWidgets('同时区行程不标注时区', (tester) async {
      // 测试环境为 UTC+8，与 Asia/Shanghai 同偏移，标注出来是冗余噪声。
      await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
      await tester.pumpAndSettle();

      expect(find.textContaining('时间按'), findsNothing);
    });

    testWidgets('跨时区行程标注时间基准与时差', (tester) async {
      await tester.pumpWidget(
        wrap(FakeWritableRepository(buildPlan(timezone: 'Asia/Tokyo'))),
      );
      await tester.pumpAndSettle();

      // 跨时区时用户必须知道表上的钟点是哪儿的时间。
      expect(find.textContaining('时间按 Asia/Tokyo 显示'), findsOneWidget);
      expect(find.textContaining('相差 +1 小时'), findsOneWidget);
    });

    testWidgets('选择新时区后调用 changeTripTimezone', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();

      await openTimezonePicker(tester);
      expect(find.text('选择行程时区'), findsOneWidget);
      // 语义必须讲清楚，否则用户不知道时间会不会跟着变。
      expect(find.textContaining('保留当地钟点'), findsOneWidget);

      await tester.tap(find.text('日本（东京）'));
      await tester.pumpAndSettle();

      expect(repository.calls.single['op'], 'timezone');
      expect(repository.calls.single['timezone'], 'Asia/Tokyo');
    });

    testWidgets('当前时区不可再选', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openTimezonePicker(tester);

      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '中国大陆（北京时间）'),
      );
      expect(tile.onTap, isNull);
      expect(tile.trailing, isNotNull);
    });

    testWidgets('取消选择不产生写入', (tester) async {
      final repository = FakeWritableRepository(buildPlan());
      await tester.pumpWidget(wrap(repository));
      await tester.pumpAndSettle();
      await openTimezonePicker(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      await tester.pumpAndSettle();

      expect(repository.calls, isEmpty);
    });
  });

  group('时区列表', () {
    test('全部为时区库可识别的 IANA 标识', () {
      for (final item in commonTimezones) {
        expect(
          TripTimeZone.isSupported(item.id),
          isTrue,
          reason: '${item.id} 不被时区库识别，选中后写入会被库端拒绝',
        );
      }
    });

    test('标识不重复', () {
      final ids = commonTimezones.map((item) => item.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });
}
