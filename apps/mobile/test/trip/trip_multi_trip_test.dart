import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_controller.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

/// 多行程的读取、切换与呈现。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  Widget wrap(TripRepository repository) => MaterialApp(
    home: Scaffold(body: TripPage(repository: repository)),
  );

  // 单日单项行程，日期与项均有真实 id。
  TripPlan buildPlan({
    required String id,
    required String title,
    String date = '2026-09-01',
    String itemTitle = '海鲜面馆',
  }) {
    return TripMapper.planFromRow({
      'id': id,
      'title': title,
      'timezone': 'Asia/Shanghai',
      'revision': 1,
      'trip_days': [
        {
          'id': '$id-day-1',
          'local_date': date,
          'trip_items': [
            {
              'id': '$id-item-1',
              'trip_day_id': '$id-day-1',
              'item_type': 'place_visit',
              'title': itemTitle,
              'planned_start_at': '${date}T04:00:00+00:00',
              'planned_end_at': '${date}T05:00:00+00:00',
              'time_slot': 'lunch',
              'position': 0,
              'status': 'planned',
            },
          ],
        },
      ],
    });
  }

  group('控制器', () {
    test('载入时同时取出行程列表', () async {
      final repository = FakeWritableRepository(
        buildPlan(id: 'trip-a', title: '大连寻味'),
        others: [buildPlan(id: 'trip-b', title: '东京寻味')],
      );
      final controller = TripController(repository);
      addTearDown(controller.dispose);

      await controller.load();

      final state = controller.state as TripLoaded;
      expect(state.trips.length, 2);
      expect(controller.selectedTripId, 'trip-a');
    });

    test('selectTrip 切换到另一个行程', () async {
      final repository = FakeWritableRepository(
        buildPlan(id: 'trip-a', title: '大连寻味'),
        others: [buildPlan(id: 'trip-b', title: '东京寻味', itemTitle: '拉面店')],
      );
      final controller = TripController(repository);
      addTearDown(controller.dispose);
      await controller.load();

      await controller.selectTrip('trip-b');

      final state = controller.state as TripLoaded;
      expect(state.plan.id, 'trip-b');
      expect(state.plan.title, '东京寻味');
      expect(controller.selectedTripId, 'trip-b');
    });

    test('选中项失效时回退到默认行程而非显示暂无行程', () async {
      // 删除当前行程后仍指向它会读到空结果，此前会表现为「明明还有行程却显示暂无」。
      final repository = _StaleSelectionRepository(
        buildPlan(id: 'trip-a', title: '大连寻味'),
      );
      final controller = TripController(repository);
      addTearDown(controller.dispose);

      await controller.selectTrip('trip-deleted');

      expect(controller.state, isA<TripLoaded>());
      expect((controller.state as TripLoaded).plan.id, 'trip-a');
      expect(controller.selectedTripId, 'trip-a');
    });
  });

  group('行程页', () {
    testWidgets('多行程时页头标注总数且标题可点', (tester) async {
      await tester.pumpWidget(
        wrap(
          FakeWritableRepository(
            buildPlan(id: 'trip-a', title: '大连寻味'),
            others: [buildPlan(id: 'trip-b', title: '东京寻味')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('我的行程 · 共 2 个'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('单个行程时不给出切换入口', (tester) async {
      await tester.pumpWidget(
        wrap(FakeWritableRepository(buildPlan(id: 'trip-a', title: '大连寻味'))),
      );
      await tester.pumpAndSettle();

      expect(find.text('我的行程'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('从切换器选择后行程随之更新', (tester) async {
      await tester.pumpWidget(
        wrap(
          FakeWritableRepository(
            buildPlan(id: 'trip-a', title: '大连寻味'),
            others: [buildPlan(id: 'trip-b', title: '东京寻味', itemTitle: '拉面店')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('切换行程'), findsOneWidget);

      await tester.tap(find.text('东京寻味'));
      await tester.pumpAndSettle();

      // 切换后时间表内容随之替换。
      expect(find.text('拉面店'), findsWidgets);
      expect(find.text('海鲜面馆'), findsNothing);
    });
  });
}

/// 列表里没有被选中的那个行程，用于覆盖选中项失效的回退。
class _StaleSelectionRepository implements TripRepository {
  _StaleSelectionRepository(this.plan);

  final TripPlan plan;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    // 只认识自己那一个；其余 id 一律读不到。
    if (tripId == null || tripId == plan.id) return plan;
    return null;
  }

  @override
  Future<List<TripSummary>> listTrips() async => [
    TripSummary(
      id: plan.id,
      title: plan.title,
      startDate: plan.days.first.date,
      endDate: plan.days.last.date,
      timezone: plan.timezone,
    ),
  ];
}
