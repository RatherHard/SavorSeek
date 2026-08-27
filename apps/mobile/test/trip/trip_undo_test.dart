import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

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

  Future<void> openDelete(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
  }

  testWidgets('编辑成功后提供一次性撤销', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('海鲜面馆').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '节点名称'), '新名字');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(repository.calls.single['op'], 'edit');
    expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();

    expect(repository.calls.last['op'], 'edit');
    expect(repository.calls.last['title'], '海鲜面馆');
  });

  testWidgets('硬删除不提供撤销', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await openDelete(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repository.calls.last['op'], 'delete');
    expect(find.widgetWithText(SnackBarAction, '撤销'), findsNothing);
  });

  testWidgets('添加普通节点后可撤销并删除新建项', (tester) async {
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
    expect(repository.calls.last['tripItemId'], 'new-item');
  });

  testWidgets('撤销冲突时给出提示', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('海鲜面馆').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    repository.error = const TripRepositoryException(
      '行程已被其他操作更新，请重新加载后再试。',
      kind: TripRepositoryErrorKind.conflict,
    );
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请重新加载后再试'), findsOneWidget);
  });
}
