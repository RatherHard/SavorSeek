import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

/// 多选与批量操作。
///
/// 批量走独立 RPC 而非循环单项：每次单项写入都会递增 revision，循环到第二次
/// 就会因 expected_revision 过期收到 P0002（见 待办.md）。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  Widget wrap(FakeWritableRepository repository) => MaterialApp(
    home: TripDetailPage(repository: repository, tripId: 'trip-1'),
  );

  FakeWritableRepository buildRepository() {
    return FakeWritableRepository(
      TripMapper.planFromRow({
        'id': 'trip-1',
        'title': '大连两日寻味',
        'timezone': 'Asia/Shanghai',
        'revision': 7,
        'trip_days': [
          {
            'id': 'day-1',
            'local_date': '2026-09-01',
            'trip_items': [
              {
                'id': 'item-1',
                'trip_day_id': 'day-1',
                'item_type': 'place_visit',
                'title': '海鲜面馆',
                'planned_start_at': '2026-09-01T04:00:00+00:00',
                'planned_end_at': '2026-09-01T05:00:00+00:00',
                'time_slot': 'lunch',
                'position': 0,
                'status': 'planned',
              },
              {
                'id': 'item-2',
                'trip_day_id': 'day-1',
                'item_type': 'place_visit',
                'title': '烧烤店',
                'planned_start_at': '2026-09-01T11:00:00+00:00',
                'planned_end_at': '2026-09-01T12:00:00+00:00',
                'time_slot': 'dinner',
                'position': 1,
                'status': 'planned',
              },
            ],
          },
        ],
      }),
    );
  }

  /// 长按第一张卡片进入多选态。
  Future<void> enterSelection(WidgetTester tester) async {
    await tester.longPress(find.text('海鲜面馆').last);
    await tester.pumpAndSettle();
  }

  testWidgets('长按进入多选态并显示操作条', (tester) async {
    await tester.pumpWidget(wrap(buildRepository()));
    await tester.pumpAndSettle();

    // 常态下没有操作条，「添加节点」可见。
    expect(find.text('添加节点'), findsOneWidget);

    await enterSelection(tester);

    expect(find.text('已选 1 项'), findsOneWidget);
    // 多选态下换成操作条，两者不并存。
    expect(find.text('添加节点'), findsNothing);
  });

  testWidgets('可累加选中多项', (tester) async {
    await tester.pumpWidget(wrap(buildRepository()));
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.text('烧烤店').last);
    await tester.pumpAndSettle();

    expect(find.text('已选 2 项'), findsOneWidget);
  });

  testWidgets('批量删除一次调用带上全部 id 与同一个 revision', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();
    await enterSelection(tester);
    await tester.tap(find.text('烧烤店').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repository.calls.length, 1);
    expect(repository.calls.single['op'], 'batchDelete');
    expect(repository.calls.single['ids'], 'item-1,item-2');
    expect(repository.calls.single['expectedRevision'], 7);
  });

  testWidgets('批量删除后退出多选态', (tester) async {
    await tester.pumpWidget(wrap(buildRepository()));
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已选'), findsNothing);
    expect(find.text('添加节点'), findsOneWidget);
  });

  testWidgets('批量删除需二次确认', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除这 1 个行程项？'), findsOneWidget);
    // 硬删除不可恢复，必须讲清与「取消」的区别。
    expect(find.textContaining('无法恢复'), findsOneWidget);
    expect(repository.calls, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repository.calls.single['op'], 'batchDelete');
    expect(repository.calls.single['ids'], 'item-1');
  });

  testWidgets('放弃确认不产生写入', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '返回'));
    await tester.pumpAndSettle();

    expect(repository.calls, isEmpty);
    // 放弃后仍留在多选态，用户可继续调整选择。
    expect(find.text('已选 1 项'), findsOneWidget);
  });

  testWidgets('冲突时给出提示', (tester) async {
    final repository = buildRepository()
      ..error = const TripRepositoryException(
        '行程已被其他操作更新，请重新加载后再试。',
        kind: TripRepositoryErrorKind.conflict,
      );
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请重新加载后再试'), findsOneWidget);
  });

  testWidgets('退出按钮清空选择', (tester) async {
    await tester.pumpWidget(wrap(buildRepository()));
    await tester.pumpAndSettle();
    await enterSelection(tester);

    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已选'), findsNothing);
  });
}
