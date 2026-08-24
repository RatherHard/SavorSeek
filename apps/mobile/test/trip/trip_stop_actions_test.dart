import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_stop_actions.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

/// 写入编排的单元测试。
///
/// 不 pumpWidget：这些规则（冲突重载、忙碌互斥、撤销取值）与任何 widget 无关，
/// 此前只能靠整页 widget 测试间接覆盖，一旦失败很难定位到具体哪条规则被破坏。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  /// 两日东京行程，首日 19:00（当地）有一项，revision 为 4。
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

  /// 建一个编排对象，并把 reload 次数与 outcome 记录下来。
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

  group('冲突处理', () {
    test('冲突时广播失败并触发重载', () async {
      final ctx = build();
      ctx.writer.error = const TripRepositoryException(
        '行程已被其他操作更新，请重新加载后再试。',
        kind: TripRepositoryErrorKind.conflict,
      );
      final plan = buildPlan();

      await ctx.actions.cancel(plan: plan, stop: plan.days.first.stops.first);
      await pumpEventQueue();

      expect(ctx.outcomes.single, isA<TripActionFailed>());
      // 冲突意味着服务端已变，必须重读让 revision 与 UI 对齐后用户才能重试。
      expect(ctx.reloadCount(), 1);
    });

    test('非冲突失败不触发重载', () async {
      // 网络失败时重读多半也会失败，徒增一次请求与一次闪烁。
      final ctx = build();
      ctx.writer.error = const TripRepositoryException(
        '无法连接行程服务。',
        kind: TripRepositoryErrorKind.network,
      );
      final plan = buildPlan();

      await ctx.actions.cancel(plan: plan, stop: plan.days.first.stops.first);
      await pumpEventQueue();

      expect(ctx.outcomes.single, isA<TripActionFailed>());
      expect(ctx.reloadCount(), 0);
    });

    test('成功后重载并广播成功文案', () async {
      final ctx = build();
      final plan = buildPlan();

      await ctx.actions.cancel(plan: plan, stop: plan.days.first.stops.first);
      await pumpEventQueue();

      expect(ctx.reloadCount(), 1);
      final outcome = ctx.outcomes.single as TripActionSucceeded;
      expect(outcome.message, '已取消：寿司大');
      // 取消可反悔，必须给出撤销。
      expect(outcome.undo, isNotNull);
    });

    test('硬删除不提供撤销', () async {
      // 记录已不存在，无从恢复；给出撤销按钮点了只会报错。
      final ctx = build();
      final plan = buildPlan();

      await ctx.actions.delete(plan: plan, stop: plan.days.first.stops.first);
      await pumpEventQueue();

      expect((ctx.outcomes.single as TripActionSucceeded).undo, isNull);
    });
  });

  group('忙碌互斥', () {
    test('写入进行中时第二次调用被丢弃', () async {
      final ctx = build();
      final plan = buildPlan();
      final gate = Completer<void>();
      ctx.writer.gate = gate;

      final first = ctx.actions.cancel(
        plan: plan,
        stop: plan.days.first.stops.first,
      );
      await pumpEventQueue();
      expect(ctx.actions.isBusy.value, isTrue);

      // 第一笔还没落地就再点一次：必须被丢弃，否则两笔用同一个
      // expected_revision，第二笔必然收到 P0002。
      await ctx.actions.cancel(plan: plan, stop: plan.days.first.stops.first);
      expect(ctx.writer.calls.length, 1);

      gate.complete();
      await first;
      expect(ctx.actions.isBusy.value, isFalse);
    });

    test('失败后忙碌标志复位', () async {
      final ctx = build();
      ctx.writer.error = const TripRepositoryException('boom');
      final plan = buildPlan();

      await ctx.actions.cancel(plan: plan, stop: plan.days.first.stops.first);

      // 不复位的话一次失败就会让页面永久拒绝后续写入。
      expect(ctx.actions.isBusy.value, isFalse);
    });
  });

  group('撤销', () {
    test('批量取消的撤销逐项递进 revision', () async {
      // restore_trip_item 没有批量版，必须逐项调用；沿用同一个 revision 会从
      // 第二项起报 P0002。
      final ctx = build();
      final plan = buildPlan();

      await ctx.actions.batchCancel(
        plan: plan,
        stopIds: const ['item-1', 'item-2', 'item-3'],
      );
      await pumpEventQueue();
      final undo = (ctx.outcomes.single as TripActionSucceeded).undo!;
      ctx.writer.calls.clear();

      await ctx.actions.undo(undo, currentRevision: 10);

      final restores = ctx.writer.calls
          .where((call) => call['op'] == 'restore')
          .toList();
      expect(restores.map((call) => call['tripItemId']), [
        'item-1',
        'item-2',
        'item-3',
      ]);
      // 每次都用上一次返回的 revision 往下走。
      expect(restores.map((call) => call['expectedRevision']), [10, 11, 12]);
    });

    test('批量取消只发一次调用，不循环单项', () async {
      final ctx = build();
      final plan = buildPlan();

      await ctx.actions.batchCancel(
        plan: plan,
        stopIds: const ['item-1', 'item-2'],
      );

      expect(ctx.writer.calls, hasLength(1));
      expect(ctx.writer.calls.single['op'], 'batchCancel');
      expect(ctx.writer.calls.single['expectedRevision'], 4);
    });

    test('空选择不产生写入', () async {
      final ctx = build();

      await ctx.actions.batchCancel(plan: buildPlan(), stopIds: const []);

      expect(ctx.writer.calls, isEmpty);
    });

    test('改期的撤销使用写入前的原值', () async {
      final ctx = build();
      final plan = buildPlan();
      final stop = plan.days.first.stops.first;

      // 从 day-1 19:00 改到 day-2 12:00。
      await ctx.actions.reschedule(
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
      );
      await pumpEventQueue();
      final write = ctx.writer.calls.single;
      // 东京 12:00 → UTC 03:00，按设备时区（UTC+8）会错成 04:00。
      expect(write['tripDayId'], 'day-2');
      expect(write['startUtc'], '2026-09-02T03:00:00.000Z');
      expect(write['endUtc'], '2026-09-02T05:00:00.000Z');

      final undo = (ctx.outcomes.single as TripActionSucceeded).undo!;
      ctx.writer.calls.clear();
      await ctx.actions.undo(undo, currentRevision: 9);

      // 逆操作必须回到原来那一天的原起止时刻与原时段。
      final back = ctx.writer.calls.single;
      expect(back['tripDayId'], 'day-1');
      expect(back['startUtc'], '2026-09-01T10:00:00.000Z');
      expect(back['endUtc'], '2026-09-01T11:00:00.000Z');
      expect(back['timeSlot'], 'dinner');
      // 撤销用「撤销时」的最新 revision，而不是被撤销那次所用的 4。
      expect(back['expectedRevision'], 9);
    });

    test('编辑的撤销写回原标题与原备注', () async {
      final ctx = build();
      final plan = buildPlan();
      final stop = plan.days.first.stops.first;

      await ctx.actions.updateItem(
        plan: plan,
        stop: stop,
        title: '新名字',
        notes: '新备注',
      );
      await pumpEventQueue();
      final undo = (ctx.outcomes.single as TripActionSucceeded).undo!;
      ctx.writer.calls.clear();

      await ctx.actions.undo(undo, currentRevision: 11);

      final back = ctx.writer.calls.single;
      expect(back['title'], '寿司大');
      // 原本没有备注，逆操作应把它清空而不是留下「新备注」。
      expect(back['notes'], isNull);
      expect(back['expectedRevision'], 11);
    });

    test('添加节点的撤销删除新建的那一项', () async {
      // 新项 id 只能从写入结果取得，故用可变量在两个闭包间传递。
      final ctx = build();
      final plan = buildPlan();

      await ctx.actions.addBreak(
        plan: plan,
        tripDayId: 'day-1',
        dayDate: DateTime(2026, 9, 1),
        title: '回酒店休息',
        hour: 15,
        minute: 0,
        duration: const Duration(minutes: 30),
        timeSlot: TripStopType.afternoonTea,
      );
      await pumpEventQueue();
      final undo = (ctx.outcomes.single as TripActionSucceeded).undo!;
      ctx.writer.calls.clear();

      await ctx.actions.undo(undo, currentRevision: 6);

      expect(ctx.writer.calls.single['op'], 'delete');
      expect(ctx.writer.calls.single['tripItemId'], 'created-item');
    });

    test('撤销失败时广播失败', () async {
      final ctx = build();
      final plan = buildPlan();
      await ctx.actions.cancel(plan: plan, stop: plan.days.first.stops.first);
      await pumpEventQueue();
      final undo = (ctx.outcomes.single as TripActionSucceeded).undo!;
      ctx.outcomes.clear();
      ctx.writer.error = const TripRepositoryException('撤销失败');

      await ctx.actions.undo(undo, currentRevision: 5);
      await pumpEventQueue();

      expect(ctx.outcomes.single, isA<TripActionFailed>());
    });
  });

  group('时区', () {
    test('无效时区不抛出，转为失败结果', () async {
      // 编排层不应把异常抛给 UI：它已订阅 outcomes，两条错误通道会漏掉一条。
      final ctx = build();
      final plan = buildPlan().copyWith(timezone: 'Not/AZone');

      await ctx.actions.addBreak(
        plan: plan,
        tripDayId: 'day-1',
        dayDate: DateTime(2026, 9, 1),
        title: '节点',
        hour: 12,
        minute: 0,
        duration: const Duration(hours: 1),
        timeSlot: TripStopType.lunch,
      );
      await pumpEventQueue();

      expect(ctx.outcomes.single, isA<TripActionFailed>());
      expect(ctx.writer.calls, isEmpty);
    });
  });
}

/// 记录调用的写入器。
///
/// 每次写入把 revision 自增一次，与库端一致，好让撤销的递进能被断言。
class _FakeWriter implements TripWriter {
  final List<Map<String, Object?>> calls = [];

  /// 非空时所有写入抛出该异常。
  TripRepositoryException? error;

  /// 非空时写入会等待它完成，用于制造「进行中」的时间窗。
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
  }) {
    return _record({
      'op': 'reschedule',
      'tripItemId': tripItemId,
      'tripDayId': tripDayId,
      'expectedRevision': expectedRevision,
      'startUtc': plannedStartAt.toUtc().toIso8601String(),
      'endUtc': plannedEndAt.toUtc().toIso8601String(),
      'timeSlot': timeSlot.wireName,
    }, () => TripWriteResult(id: tripItemId, revision: _revision));
  }

  @override
  Future<TripWriteResult> cancelTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) {
    return _record({
      'op': 'cancel',
      'tripItemId': tripItemId,
      'expectedRevision': expectedRevision,
    }, () => TripWriteResult(id: tripItemId, revision: _revision));
  }

  @override
  Future<TripWriteResult> restoreTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) {
    // 逐项恢复时每次返回的 revision 必须比传入的大一，否则测不出递进。
    return _record({
      'op': 'restore',
      'tripItemId': tripItemId,
      'expectedRevision': expectedRevision,
    }, () => TripWriteResult(id: tripItemId, revision: expectedRevision + 1));
  }

  @override
  Future<TripWriteResult> updateTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    String? idempotencyKey,
  }) {
    return _record({
      'op': 'updateItem',
      'tripItemId': tripItemId,
      'title': title,
      'notes': notes,
      'expectedRevision': expectedRevision,
    }, () => TripWriteResult(id: tripItemId, revision: _revision));
  }

  @override
  Future<int> deleteTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) {
    return _record({
      'op': 'delete',
      'tripItemId': tripItemId,
      'expectedRevision': expectedRevision,
    }, () => _revision);
  }

  @override
  Future<int> changeTripTimezone({
    required String tripId,
    required int expectedRevision,
    required String timezone,
    String? idempotencyKey,
  }) {
    return _record({
      'op': 'timezone',
      'timezone': timezone,
      'expectedRevision': expectedRevision,
    }, () => 1);
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
  }) {
    return _record({
      'op': 'addBreak',
      'tripDayId': tripDayId,
      'title': title,
      'expectedRevision': expectedRevision,
      'startUtc': plannedStartAt.toUtc().toIso8601String(),
      'notes': notes,
    }, () => TripWriteResult(id: 'created-item', revision: _revision));
  }

  @override
  Future<int> countItemsOnDay(String tripDayId) async => 0;

  @override
  Future<TripBatchResult> batchCancelTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) {
    return _record(
      {
        'op': 'batchCancel',
        'ids': tripItemIds.join(','),
        'expectedRevision': expectedRevision,
      },
      () => TripBatchResult(
        affectedCount: tripItemIds.length,
        revision: _revision,
      ),
    );
  }

  @override
  Future<TripBatchResult> batchDeleteTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) {
    return _record(
      {
        'op': 'batchDelete',
        'ids': tripItemIds.join(','),
        'expectedRevision': expectedRevision,
      },
      () => TripBatchResult(
        affectedCount: tripItemIds.length,
        revision: _revision,
      ),
    );
  }
}
