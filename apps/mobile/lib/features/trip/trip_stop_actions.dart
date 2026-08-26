import 'dart:async';

import 'package:flutter/foundation.dart';

import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_time_zone.dart';

/// 一次写入的结果。
sealed class TripActionOutcome {
  const TripActionOutcome();
}

final class TripActionSucceeded extends TripActionOutcome {
  const TripActionSucceeded(this.message, {this.undo});

  final String message;

  /// 非空时提示条显示「撤销」。
  final TripUndo? undo;
}

final class TripActionFailed extends TripActionOutcome {
  const TripActionFailed(this.message);

  final String message;
}

/// 一次可撤销操作的逆操作。
///
/// 包成具名类型而非裸函数：函数类型出现在 [TripActionSucceeded] 与
/// [TripStopActions.undo] 两处，裸 `Future<void> Function(TripWriter, int)`
/// 读起来看不出参数含义。
@immutable
class TripUndo {
  const TripUndo(this.apply);

  /// [revision] 是「撤销时」的最新修订号，由 [TripStopActions.undo] 传入。
  final Future<void> Function(TripWriter writer, int revision) apply;
}

/// 行程写入编排。
///
/// 从 UI 抽出而非留在 State 中：九种写入共享同一套 revision 冲突处理、忙碌互斥
/// 与撤销取值规则，这些规则的正确性不该只靠 pumpWidget 间接覆盖。
///
/// 不持有 [TripPlan]：`revision` 是乐观并发控制的核心，只允许有一个来源——
/// `TripController` 的当前状态。内部再存一份当前 plan 会多出一处需要与
/// `TripController` 同步的状态，两处 revision 不一致时的 bug 很隐蔽。代价是每个
/// 方法都要传入 plan，签名较长。
class TripStopActions {
  TripStopActions({required this.writer, required this.reload});

  final TripWriter writer;

  /// 写入成功后重新读取行程，由调用方接到 `TripController.load`。
  final Future<void> Function() reload;

  final ValueNotifier<bool> _isBusy = ValueNotifier(false);
  final StreamController<TripActionOutcome> _outcomes =
      StreamController<TripActionOutcome>.broadcast();

  /// 写入进行中，用于阻止重复提交。
  ValueListenable<bool> get isBusy => _isBusy;

  /// 每次写入的结果：成功文案加可选的撤销闭包，或失败原因。
  ///
  /// 用流而非给每个方法传 onSuccess/onError 回调：结果最终要变成一条 SnackBar，
  /// 而 SnackBar 需要 context。让 UI 统一 listen 比每个方法各接一次干净，也让
  /// 「撤销」这个附带动作只挂在 outcome 上一处。
  Stream<TripActionOutcome> get outcomes => _outcomes.stream;

  /// 改期：调整某个行程项的日期与时间。
  ///
  /// [currentDayId] / [currentDayDate] 是项当前所属的那一天，撤销时用；
  /// [targetDayId] / [targetDayDate] 是目标日，可跨天。
  Future<void> reschedule({
    required TripPlan plan,
    required TripStop stop,
    required String currentDayId,
    required DateTime currentDayDate,
    required String targetDayId,
    required DateTime targetDayDate,
    required int hour,
    required int minute,
    required Duration duration,
    required TripStopType timeSlot,
  }) async {
    // 撤销所需的原值必须在写入前留存：写入成功后再读已是新值。
    final originalStart = stop.startAt;
    final originalDuration = stop.endAt.difference(stop.startAt);
    final originalType = stop.type;

    await _run(
      (writer) {
        final start = _instant(
          localDate: targetDayDate,
          timezone: plan.timezone,
          hour: hour,
          minute: minute,
        );
        return writer.rescheduleTripItem(
          tripId: plan.id,
          expectedRevision: plan.revision,
          tripItemId: stop.id,
          tripDayId: targetDayId,
          plannedStartAt: start,
          plannedEndAt: start.add(duration),
          timeSlot: timeSlot,
        );
      },
      success: '已改期：${stop.title}',
      // 逆操作是放回原来那一天的原起止时刻。
      undo: TripUndo((writer, revision) {
        final start = _instant(
          localDate: currentDayDate,
          timezone: plan.timezone,
          hour: originalStart.hour,
          minute: originalStart.minute,
        );
        return writer.rescheduleTripItem(
          tripId: plan.id,
          expectedRevision: revision,
          tripItemId: stop.id,
          tripDayId: currentDayId,
          plannedStartAt: start,
          plannedEndAt: start.add(originalDuration),
          timeSlot: originalType,
        );
      }),
    );
  }

  /// 硬删除。二次确认由 UI 负责，此处只执行。
  ///
  /// 不提供撤销：记录已不存在，无从恢复。
  Future<void> delete({required TripPlan plan, required TripStop stop}) {
    return _run(
      (writer) => writer.deleteTripItem(
        tripId: plan.id,
        expectedRevision: plan.revision,
        tripItemId: stop.id,
      ),
      success: '已删除：${stop.title}',
    );
  }

  /// 批量硬删除。二次确认由 UI 负责。
  Future<bool> batchDelete({
    required TripPlan plan,
    required List<String> stopIds,
  }) {
    final ids = List<String>.unmodifiable(stopIds);
    if (ids.isEmpty) return Future<bool>.value(false);
    return _runResult(
      (writer) => writer.batchDeleteTripItems(
        tripId: plan.id,
        expectedRevision: plan.revision,
        tripItemIds: ids,
      ),
      success: '已删除 ${ids.length} 个行程项',
    );
  }

  /// 添加一个自由安排节点。
  Future<void> addBreak({
    required TripPlan plan,
    required String tripDayId,
    required DateTime dayDate,
    required String title,
    required int hour,
    required int minute,
    required Duration duration,
    required TripStopType timeSlot,
    String? notes,
  }) async {
    // 新项的 id 只能从写入结果取得，故用一个可变量在写入闭包与撤销闭包之间传递：
    // 撤销闭包在写入成功后才会被调用，届时已被赋值。
    String? createdId;
    await _run(
      (writer) async {
        final start = _instant(
          localDate: dayDate,
          timezone: plan.timezone,
          hour: hour,
          minute: minute,
        );
        final result = await writer.addBreakItem(
          tripId: plan.id,
          expectedRevision: plan.revision,
          tripDayId: tripDayId,
          title: title,
          plannedStartAt: start,
          plannedEndAt: start.add(duration),
          timeSlot: timeSlot,
          notes: notes,
        );
        createdId = result.id;
        return result;
      },
      success: '已添加节点：$title',
      // 加入行程的逆操作是删除刚建的那一项。
      undo: TripUndo((writer, revision) async {
        final id = createdId;
        if (id == null) return;
        await writer.deleteTripItem(
          tripId: plan.id,
          expectedRevision: revision,
          tripItemId: id,
        );
      }),
    );
  }

  /// 添加一个地点节点。
  ///
  /// 与 [addBreak] 的差别只在坐标：地点节点带 `place_snapshot`，因此能上地图。
  /// [latitude] / [longitude] 为空时仍会写入，只是该节点不参与路线绘制。
  Future<void> addPlace({
    required TripPlan plan,
    required String tripDayId,
    required DateTime dayDate,
    required String placeId,
    required String title,
    required int hour,
    required int minute,
    required Duration duration,
    required TripStopType timeSlot,
    double? latitude,
    double? longitude,
    String? notes,
  }) async {
    // 新项的 id 只能从写入结果取得，故用可变量在写入闭包与撤销闭包之间传递。
    String? createdId;
    await _run(
      (writer) async {
        final start = _instant(
          localDate: dayDate,
          timezone: plan.timezone,
          hour: hour,
          minute: minute,
        );
        final result = await writer.addPlaceItem(
          tripId: plan.id,
          expectedRevision: plan.revision,
          tripDayId: tripDayId,
          placeId: placeId,
          title: title,
          plannedStartAt: start,
          plannedEndAt: start.add(duration),
          timeSlot: timeSlot,
          latitude: latitude,
          longitude: longitude,
          notes: notes,
        );
        createdId = result.id;
        return result;
      },
      success: '已加入行程：$title',
      // 逆操作是删除刚建的那一项。
      undo: TripUndo((writer, revision) async {
        final id = createdId;
        if (id == null) return;
        await writer.deleteTripItem(
          tripId: plan.id,
          expectedRevision: revision,
          tripItemId: id,
        );
      }),
    );
  }

  /// 一次修改节点的标题、备注、日期、时间与时长。
  Future<void> editStop({
    required TripPlan plan,
    required TripStop stop,
    required String currentDayId,
    required DateTime currentDayDate,
    required String targetDayId,
    required DateTime targetDayDate,
    required int hour,
    required int minute,
    required Duration duration,
    required TripStopType timeSlot,
    required String title,
    String? notes,
  }) async {
    final originalTitle = stop.title;
    final originalNotes = stop.note;
    final originalStart = stop.startAt;
    final originalDuration = stop.endAt.difference(stop.startAt);
    final originalType = stop.type;

    await _run(
      (writer) {
        final start = _instant(
          localDate: targetDayDate,
          timezone: plan.timezone,
          hour: hour,
          minute: minute,
        );
        return writer.editTripItem(
          tripId: plan.id,
          expectedRevision: plan.revision,
          tripItemId: stop.id,
          title: title,
          notes: notes,
          tripDayId: targetDayId,
          plannedStartAt: start,
          plannedEndAt: start.add(duration),
          timeSlot: timeSlot,
        );
      },
      success: '已更新：$title',
      undo: TripUndo((writer, revision) {
        final start = _instant(
          localDate: currentDayDate,
          timezone: plan.timezone,
          hour: originalStart.hour,
          minute: originalStart.minute,
        );
        return writer.editTripItem(
          tripId: plan.id,
          expectedRevision: revision,
          tripItemId: stop.id,
          title: originalTitle,
          notes: originalNotes,
          tripDayId: currentDayId,
          plannedStartAt: start,
          plannedEndAt: start.add(originalDuration),
          timeSlot: originalType,
        );
      }),
    );
  }

  /// 执行一次撤销。
  ///
  /// [currentRevision] 必须是「撤销时」的最新值，而不是被撤销那次操作所用的旧
  /// 值——后者早已过期，必然收到 P0002。
  Future<void> undo(TripUndo undo, {required int currentRevision}) async {
    if (_isBusy.value) return;
    _isBusy.value = true;
    try {
      await undo.apply(writer, currentRevision);
      await reload();
      _emit(const TripActionSucceeded('已撤销'));
    } on TripRepositoryException catch (error) {
      _emit(TripActionFailed(error.message));
      // 冲突说明服务端已变，重新读一次让 revision 与 UI 对齐后用户可重试。
      if (error.kind == TripRepositoryErrorKind.conflict) await reload();
    } finally {
      _isBusy.value = false;
    }
  }

  /// 执行一次写入，统一处理忙碌互斥、冲突重载与结果广播。
  Future<void> _run(
    Future<Object?> Function(TripWriter writer) write, {
    required String success,
    TripUndo? undo,
  }) async {
    if (_isBusy.value) return;
    _isBusy.value = true;
    try {
      await write(writer);
      await reload();
      _emit(TripActionSucceeded(success, undo: undo));
    } on TripRepositoryException catch (error) {
      _emit(TripActionFailed(error.message));
      if (error.kind == TripRepositoryErrorKind.conflict) await reload();
    } on TripTimeZoneException catch (error) {
      _emit(TripActionFailed(error.toString()));
    } finally {
      _isBusy.value = false;
    }
  }

  Future<bool> _runResult(
    Future<Object?> Function(TripWriter writer) write, {
    required String success,
  }) async {
    if (_isBusy.value) return false;
    _isBusy.value = true;
    try {
      await write(writer);
      await reload();
      _emit(TripActionSucceeded(success));
      return true;
    } on TripRepositoryException catch (error) {
      _emit(TripActionFailed(error.message));
      if (error.kind == TripRepositoryErrorKind.conflict) await reload();
      return false;
    } finally {
      _isBusy.value = false;
    }
  }

  void _emit(TripActionOutcome outcome) {
    if (_outcomes.isClosed) return;
    _outcomes.add(outcome);
  }

  /// 把行程时区下的墙上时间折算为 UTC 时刻。
  ///
  /// 不用 schedule_picker_sheet 的 resolveInstant：那个文件 import 了 Material，
  /// 而本类刻意不依赖 UI 层，否则就无法在纯 Dart 测试里单测。
  static DateTime _instant({
    required DateTime localDate,
    required String timezone,
    required int hour,
    required int minute,
  }) {
    return TripTimeZone.toInstant(
      timezone: timezone,
      localDate: localDate,
      hour: hour,
      minute: minute,
    );
  }

  void dispose() {
    _isBusy.dispose();
    _outcomes.close();
  }
}
