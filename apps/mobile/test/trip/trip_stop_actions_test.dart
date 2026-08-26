import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_stop_actions.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  TripPlan buildPlan() => TripMapper.planFromRow({
    'id': 'trip-tokyo',
    'title': '东京寻味',
    'timezone': 'Asia/Tokyo',
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

  ({
    TripStopActions actions,
    _FakeWriter writer,
    List<TripActionOutcome> outcomes,
    int Function() reloadCount,
  })
  build() {
    final writer = _FakeWriter();
    var reloads = 0;
    final actions = TripStopActions(
      writer: writer,
      reload: () async => reloads++,
    );
    final outcomes = <TripActionOutcome>[];
    actions.outcomes.listen(outcomes.add);
    addTearDown(actions.dispose);
    return (
      actions: actions,
      writer: writer,
      outcomes: outcomes,
      reloadCount: () => reloads,
    );
  }

  group('写入结果', () {
    test('冲突时广播失败并重载', () async {
      final ctx = build();
      ctx.writer.error = const TripRepositoryException(
        '行程已被其他操作更新，请重新加载后再试。',
        kind: TripRepositoryErrorKind.conflict,
      );

      await ctx.actions.delete(
        plan: buildPlan(),
        stop: buildPlan().days.first.stops.first,
      );
      await pumpEventQueue();

      expect(ctx.outcomes.single, isA<TripActionFailed>());
      expect(ctx.reloadCount(), 1);
    });

    test('网络失败不触发额外重载', () async {
      final ctx = build();
      ctx.writer.error = const TripRepositoryException(
        '无法连接行程服务。',
        kind: TripRepositoryErrorKind.network,
      );

      await ctx.actions.delete(
        plan: buildPlan(),
        stop: buildPlan().days.first.stops.first,
      );
      await pumpEventQueue();

      expect(ctx.outcomes.single, isA<TripActionFailed>());
      expect(ctx.reloadCount(), 0);
    });

    test('删除成功不提供撤销', () async {
      final ctx = build();
      final plan = buildPlan();
      await ctx.actions.delete(plan: plan, stop: plan.days.first.stops.first);
      await pumpEventQueue();

      final outcome = ctx.outcomes.single as TripActionSucceeded;
      expect(outcome.message, '已删除：寿司大');
      expect(outcome.undo, isNull);
    });
  });

  group('编辑', () {
    test('一次写入标题、备注与排期', () async {
      final ctx = build();
      final plan = buildPlan();
      final stop = plan.days.first.stops.first;

      await ctx.actions.editStop(
        plan: plan,
        stop: stop,
        currentDayId: 'day-1',
        currentDayDate: DateTime(2026, 9, 1),
        targetDayId: 'day-2',
        targetDayDate: DateTime(2026, 9, 2),
        hour: 12,
        minute: 0,
        duration: const Duration(hours: 2),
        timeSlot: TripStopType.lunch,
        title: '新名字',
        notes: '新备注',
      );
      await pumpEventQueue();

      final call = ctx.writer.calls.single;
      expect(call['op'], 'edit');
      expect(call['title'], '新名字');
      expect(call['notes'], '新备注');
      expect(call['tripDayId'], 'day-2');
      expect(call['startUtc'], '2026-09-02T03:00:00.000Z');
      expect(call['endUtc'], '2026-09-02T05:00:00.000Z');
      expect(call['timeSlot'], 'lunch');
    });

    test('编辑撤销一次写回原始五个字段', () async {
      final ctx = build();
      final plan = buildPlan();
      final stop = plan.days.first.stops.first;

      await ctx.actions.editStop(
        plan: plan,
        stop: stop,
        currentDayId: 'day-1',
        currentDayDate: DateTime(2026, 9, 1),
        targetDayId: 'day-2',
        targetDayDate: DateTime(2026, 9, 2),
        hour: 12,
        minute: 0,
        duration: const Duration(hours: 2),
        timeSlot: TripStopType.lunch,
        title: '新名字',
        notes: '新备注',
      );
      await pumpEventQueue();
      final undo = (ctx.outcomes.single as TripActionSucceeded).undo!;
      ctx.writer.calls.clear();

      await ctx.actions.undo(undo, currentRevision: 11);
      final call = ctx.writer.calls.single;
      expect(call['op'], 'edit');
      expect(call['title'], '寿司大');
      expect(call['notes'], isNull);
      expect(call['tripDayId'], 'day-1');
      expect(call['startUtc'], '2026-09-01T10:00:00.000Z');
      expect(call['endUtc'], '2026-09-01T11:00:00.000Z');
      expect(call['timeSlot'], 'dinner');
      expect(call['expectedRevision'], 11);
    });
  });

  group('忙碌互斥', () {
    test('写入进行中时第二次调用被丢弃', () async {
      final ctx = build();
      final plan = buildPlan();
      final stop = plan.days.first.stops.first;
      final gate = Completer<void>();
      ctx.writer.gate = gate;

      final first = ctx.actions.delete(plan: plan, stop: stop);
      await pumpEventQueue();
      expect(ctx.actions.isBusy.value, isTrue);

      await ctx.actions.delete(plan: plan, stop: stop);
      expect(ctx.writer.calls, hasLength(1));

      gate.complete();
      await first;
      expect(ctx.actions.isBusy.value, isFalse);
    });
  });

  group('添加节点', () {
    test('普通节点走 addBreak', () async {
      final ctx = build();
      await ctx.actions.addBreak(
        plan: buildPlan(),
        tripDayId: 'day-1',
        dayDate: DateTime(2026, 9, 1),
        title: '回酒店休息',
        hour: 15,
        minute: 0,
        duration: const Duration(minutes: 30),
        timeSlot: TripStopType.afternoonTea,
      );

      expect(ctx.writer.calls.single['op'], 'addBreak');
    });

    test('地点节点保留坐标快照字段', () async {
      final ctx = build();
      await ctx.actions.addPlace(
        plan: buildPlan(),
        tripDayId: 'day-1',
        dayDate: DateTime(2026, 9, 1),
        placeId: 'place-1',
        title: '海鲜面馆',
        latitude: 38.914003,
        longitude: 121.614682,
        hour: 12,
        minute: 30,
        duration: const Duration(hours: 1),
        timeSlot: TripStopType.lunch,
      );

      final call = ctx.writer.calls.single;
      expect(call['op'], 'addPlace');
      expect(call['latitude'], 38.914003);
      expect(call['longitude'], 121.614682);
    });
  });
}

class _FakeWriter implements TripWriter {
  final List<Map<String, Object?>> calls = [];
  TripRepositoryException? error;
  Completer<void>? gate;
  int _revision = 5;

  Future<T> _record<T>(Map<String, Object?> call, T Function() result) async {
    calls.add(call);
    final pending = gate;
    if (pending != null) await pending.future;
    final failure = error;
    if (failure != null) throw failure;
    _revision++;
    return result();
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
  }) => _record({
    'op': 'reschedule',
    'tripItemId': tripItemId,
    'tripDayId': tripDayId,
    'expectedRevision': expectedRevision,
    'startUtc': plannedStartAt.toUtc().toIso8601String(),
    'endUtc': plannedEndAt.toUtc().toIso8601String(),
    'timeSlot': timeSlot.wireName,
  }, () => TripWriteResult(id: tripItemId, revision: _revision));

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
  }) => _record({
    'op': 'edit',
    'tripItemId': tripItemId,
    'tripDayId': tripDayId,
    'expectedRevision': expectedRevision,
    'title': title,
    'notes': notes,
    'startUtc': plannedStartAt.toUtc().toIso8601String(),
    'endUtc': plannedEndAt.toUtc().toIso8601String(),
    'timeSlot': timeSlot.wireName,
  }, () => TripWriteResult(id: tripItemId, revision: _revision));

  @override
  Future<TripWriteResult> updateTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    String? idempotencyKey,
  }) => _record({
    'op': 'update',
    'tripItemId': tripItemId,
    'title': title,
    'notes': notes,
  }, () => TripWriteResult(id: tripItemId, revision: _revision));

  @override
  Future<int> deleteTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) => _record({'op': 'delete', 'tripItemId': tripItemId}, () => _revision);

  @override
  Future<int> changeTripTimezone({
    required String tripId,
    required int expectedRevision,
    required String timezone,
    String? idempotencyKey,
  }) => _record({'op': 'timezone'}, () => 1);

  @override
  Future<TripWriteResult> completeTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) => _record({
    'op': 'completeTrip',
  }, () => TripWriteResult(id: tripId, revision: _revision));

  @override
  Future<TripWriteResult> cancelTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) => _record({
    'op': 'cancelTrip',
  }, () => TripWriteResult(id: tripId, revision: _revision));

  @override
  Future<int> deleteTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) => _record({'op': 'deleteTrip'}, () => 1);

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
  }) => _record({
    'op': 'addBreak',
    'title': title,
    'notes': notes,
  }, () => TripWriteResult(id: 'created-item', revision: _revision));

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
  }) => _record({
    'op': 'addPlace',
    'placeId': placeId,
    'latitude': latitude,
    'longitude': longitude,
  }, () => TripWriteResult(id: 'created-place-item', revision: _revision));

  @override
  Future<int> countItemsOnDay(String tripDayId) async => 0;

  @override
  Future<TripBatchResult> batchDeleteTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) => _record(
    {'op': 'batchDelete'},
    () =>
        TripBatchResult(affectedCount: tripItemIds.length, revision: _revision),
  );
}
