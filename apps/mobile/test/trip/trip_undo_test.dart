import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

/// 统一撤销入口。
///
/// 误操作后的第一反应是「撤销」，而不是回列表里找刚才那一项再选恢复
/// （见 待办.md）。硬删除不纳入：记录已不存在，无从恢复。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  Widget wrap(FakeWritableRepository repository) => MaterialApp(
    home: Scaffold(body: TripPage(repository: repository)),
  );

  FakeWritableRepository buildRepository() {
    return FakeWritableRepository(
      TripMapper.planFromRow({
        'id': 'trip-1',
        'title': '大连两日寻味',
        'timezone': 'Asia/Shanghai',
        'revision': 4,
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
            ],
          },
          {'id': 'day-2', 'local_date': '2026-09-02', 'trip_items': []},
        ],
      }),
    );
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
  }

  testWidgets('取消后可撤销，撤销即恢复', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repository.calls.single['op'], 'cancel');

    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();

    expect(repository.calls.last['op'], 'restore');
    expect(repository.calls.last['tripItemId'], 'item-1');
  });

  testWidgets('硬删除不提供撤销', (tester) async {
    // 记录已不存在，给出撤销按钮是在承诺做不到的事。
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repository.calls.last['op'], 'delete');
    expect(find.widgetWithText(SnackBarAction, '撤销'), findsNothing);
  });

  testWidgets('添加节点后可撤销，撤销即删除新建项', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '节点名称'), '回酒店休息');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(repository.calls.single['op'], 'addBreak');

    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();

    expect(repository.calls.last['op'], 'delete');
    // 删除的是刚创建的那一项，id 取自写入结果。
    expect(repository.calls.last['tripItemId'], 'new-item');
  });

  testWidgets('批量取消后可撤销，逐项恢复', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('海鲜面馆').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(repository.calls.single['op'], 'batchCancel');

    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();

    expect(repository.calls.last['op'], 'restore');
  });

  testWidgets('撤销失败时给出提示', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 撤销时服务端已被他方更新。
    repository.error = const TripRepositoryException(
      '行程已被其他操作更新，请重新加载后再试。',
      kind: TripRepositoryErrorKind.conflict,
    );
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请重新加载后再试'), findsOneWidget);
  });
}
