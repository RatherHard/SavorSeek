import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

/// 记录改期调用的仓库。同时实现读与写，模拟真实仓库的能力组合。
class FakeWritableRepository implements TripRepository, TripWriter {
  FakeWritableRepository(this._plan, {List<TripPlan>? others})
    : _others = others ?? const [];

  TripPlan _plan;

  /// 除当前行程外的其他行程，用于覆盖切换分支。
  final List<TripPlan> _others;

  final List<Map<String, Object?>> calls = [];
  TripRepositoryException? error;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    if (tripId == null || tripId == _plan.id) return _plan;
    for (final plan in _others) {
      if (plan.id == tripId) {
        // 切换后当前行程随之改变，与真实仓库「读到的就是选中的那个」一致。
        _plan = plan;
        return plan;
      }
    }
    return null;
  }

  @override
  Future<List<TripSummary>> listTrips() async {
    TripSummary summarize(TripPlan plan) => TripSummary(
      id: plan.id,
      title: plan.title,
      startDate: plan.days.first.date,
      endDate: plan.days.last.date,
      timezone: plan.timezone,
      status: plan.status,
    );
    return [
      summarize(_plan),
      for (final plan in _others)
        if (plan.id != _plan.id) summarize(plan),
    ];
  }

  @override
  Future<TripWriteResult> rescheduleTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String tripDayId,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? idempotencyKey,
  }) async {
    calls.add({
      'tripId': tripId,
      'expectedRevision': expectedRevision,
      'tripItemId': tripItemId,
      'tripDayId': tripDayId,
      'startUtc': plannedStartAt.toUtc().toIso8601String(),
      'endUtc': plannedEndAt.toUtc().toIso8601String(),
      'timeSlot': timeSlot.wireName,
    });
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(revision: _plan.revision + 1);
    return TripWriteResult(id: tripItemId, revision: _plan.revision);
  }

  @override
  Future<TripWriteResult> editTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    required String tripDayId,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? idempotencyKey,
  }) async {
    calls.add({
      'op': 'edit',
      'tripItemId': tripItemId,
      'tripDayId': tripDayId,
      'title': title,
      'notes': notes,
      'expectedRevision': expectedRevision,
      'startUtc': plannedStartAt.toUtc().toIso8601String(),
      'endUtc': plannedEndAt.toUtc().toIso8601String(),
      'timeSlot': timeSlot.wireName,
    });
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(revision: _plan.revision + 1);
    return TripWriteResult(id: tripItemId, revision: _plan.revision);
  }

  @override
  Future<TripWriteResult> updateTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    String? idempotencyKey,
  }) async {
    calls.add({
      'op': 'updateItem',
      'tripItemId': tripItemId,
      'title': title,
      'notes': notes,
      'expectedRevision': expectedRevision,
    });
    final failure = error;
    if (failure != null) throw failure;
    // 标题与备注写回当前 plan，便于断言重载后的呈现。
    _plan = _plan.copyWith(
      revision: _plan.revision + 1,
      days: [
        for (final day in _plan.days)
          day.copyWith(
            stops: [
              for (final stop in day.stops)
                if (stop.id == tripItemId)
                  stop.copyWith(title: title, note: notes)
                else
                  stop,
            ],
          ),
      ],
    );
    return TripWriteResult(id: tripItemId, revision: _plan.revision);
  }

  @override
  Future<int> deleteTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) async {
    calls.add({'op': 'delete', 'tripItemId': tripItemId});
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(revision: _plan.revision + 1);
    return _plan.revision;
  }

  @override
  Future<TripWriteResult> addBreakItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? notes,
    String? idempotencyKey,
  }) async {
    calls.add({
      'op': 'addBreak',
      'tripDayId': tripDayId,
      'title': title,
      'startUtc': plannedStartAt.toUtc().toIso8601String(),
      'endUtc': plannedEndAt.toUtc().toIso8601String(),
      'timeSlot': timeSlot.wireName,
      'notes': notes,
    });
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(revision: _plan.revision + 1);
    return TripWriteResult(id: 'new-item', revision: _plan.revision);
  }

  @override
  Future<TripWriteResult> addPlaceItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String placeId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    double? latitude,
    double? longitude,
    String? notes,
    String? idempotencyKey,
  }) async {
    calls.add({
      'op': 'addPlace',
      'tripDayId': tripDayId,
      'placeId': placeId,
      'title': title,
      'startUtc': plannedStartAt.toUtc().toIso8601String(),
      'endUtc': plannedEndAt.toUtc().toIso8601String(),
      'timeSlot': timeSlot.wireName,
      'latitude': latitude,
      'longitude': longitude,
      'notes': notes,
    });
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(revision: _plan.revision + 1);
    return TripWriteResult(id: 'new-place-item', revision: _plan.revision);
  }

  @override
  Future<int> countItemsOnDay(String tripDayId) async {
    for (final day in _plan.days) {
      if (day.id == tripDayId) return day.stops.length;
    }
    return 0;
  }

  @override
  Future<TripBatchResult> batchDeleteTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) async {
    calls.add({
      'op': 'batchDelete',
      'ids': tripItemIds.join(','),
      'expectedRevision': expectedRevision,
    });
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(revision: _plan.revision + 1);
    return TripBatchResult(
      affectedCount: tripItemIds.length,
      revision: _plan.revision,
    );
  }

  @override
  Future<TripWriteResult> completeTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) async {
    calls.add({'op': 'completeTrip', 'expectedRevision': expectedRevision});
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(
      revision: _plan.revision + 1,
      status: TripStatus.completed,
    );
    return TripWriteResult(id: tripId, revision: _plan.revision);
  }

  @override
  Future<TripWriteResult> cancelTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) async {
    calls.add({'op': 'cancelTrip', 'expectedRevision': expectedRevision});
    final failure = error;
    if (failure != null) throw failure;
    _plan = _plan.copyWith(
      revision: _plan.revision + 1,
      status: TripStatus.cancelled,
    );
    return TripWriteResult(id: tripId, revision: _plan.revision);
  }

  @override
  Future<int> deleteTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) async {
    calls.add({'op': 'deleteTrip', 'expectedRevision': expectedRevision});
    final failure = error;
    if (failure != null) throw failure;
    return 1;
  }

  /// 当前行程，供测试断言写入后的状态。
  TripPlan get plan => _plan;
}

/// 只读仓库，用于验证无写入能力时不给出改期入口。
class ReadOnlyRepository implements TripRepository {
  ReadOnlyRepository(this.plan);

  final TripPlan plan;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async => plan;

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

/// 两日东京行程，首日 19:00 有一项。
TripPlan buildTokyoPlan() => TripMapper.planFromRow({
  'id': 'trip-tokyo',
  'title': '东京寻味',
  'timezone': 'Asia/Tokyo',
  'revision': 4,
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
    {'id': 'day-2', 'local_date': '2026-09-02', 'trip_items': <dynamic>[]},
  ],
});

Widget wrap(TripRepository repository, {String tripId = 'trip-tokyo'}) =>
    MaterialApp(
      home: TripDetailPage(repository: repository, tripId: tripId),
    );

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  testWidgets('行程项显示行程当地时间，并给出改期入口', (tester) async {
    await tester.pumpWidget(wrap(FakeWritableRepository(buildTokyoPlan())));
    await tester.pumpAndSettle();

    // 东京 19:00，而非设备时区折算出的 18:00。
    expect(find.text('晚餐 · 19:00–20:00'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('只读仓库不给出改期入口', (tester) async {
    await tester.pumpWidget(wrap(ReadOnlyRepository(buildTokyoPlan())));
    await tester.pumpAndSettle();

    // 点了没有反馈的入口比没有入口更糟。
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('改期表单以现有排期为初值', (tester) async {
    await tester.pumpWidget(wrap(FakeWritableRepository(buildTokyoPlan())));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑节点'), findsOneWidget);
    expect(find.text('一次修改名称、备注与排期。'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);

    // 初值取自当前排期。19:00 在时间轴与表单中各出现一次（表单浮于列表之上），
    // 故用 findsWidgets；日期只在表单内出现。
    expect(find.text('19:00'), findsWidgets);
    expect(find.text('2026-09-01（周二）'), findsOneWidget);
    // 时长初值为 1 小时，对应选中的时长档位。
    expect(find.text('1 小时'), findsWidgets);
  });

  testWidgets('提交改期时按行程时区折算并带上 expected_revision', (tester) async {
    final repository = FakeWritableRepository(buildTokyoPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.calls, hasLength(1));
    final call = repository.calls.single;
    expect(call['tripItemId'], 'item-1');
    expect(call['tripDayId'], 'day-1');
    expect(call['expectedRevision'], 4);
    // 东京 19:00 折算为 UTC 10:00——按设备时区（UTC+8）会错成 11:00。
    expect(call['startUtc'], '2026-09-01T10:00:00.000Z');
    expect(call['endUtc'], '2026-09-01T11:00:00.000Z');
    expect(call['timeSlot'], 'dinner');
  });

  testWidgets('冲突时给出提示', (tester) async {
    final repository = FakeWritableRepository(buildTokyoPlan())
      ..error = const TripRepositoryException(
        '行程已被其他操作更新，请重新加载后再试。',
        kind: TripRepositoryErrorKind.conflict,
      );
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.textContaining('请重新加载'), findsOneWidget);
  });

  testWidgets('取消改期不产生写入', (tester) async {
    final repository = FakeWritableRepository(buildTokyoPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repository.calls, isEmpty);
  });

  testWidgets('终态项不可点', (tester) async {
    final plan = TripMapper.planFromRow({
      'id': 'trip-1',
      'title': '已完成行程',
      'timezone': 'Asia/Tokyo',
      'revision': 2,
      'trip_days': [
        {
          'id': 'day-1',
          'local_date': '2026-09-01',
          'trip_items': [
            {
              'id': 'item-done',
              'trip_day_id': 'day-1',
              'item_type': 'place_visit',
              'title': '已到访的店',
              'planned_start_at': '2026-09-01T10:00:00+00:00',
              'planned_end_at': '2026-09-01T11:00:00+00:00',
              'time_slot': 'dinner',
              'position': 0,
              'status': 'completed',
            },
          ],
        },
      ],
    });

    await tester.pumpWidget(
      wrap(FakeWritableRepository(plan), tripId: 'trip-1'),
    );
    await tester.pumpAndSettle();

    // 给已完成的到访改时间会让历史失真，库端也会拒绝。
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });
}
