import 'dart:async';

import 'package:flutter/foundation.dart';

import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_stop_actions.dart';

/// 行程级写入编排。
///
/// 与节点写入分开，避免把「完成 / 取消 / 删除整份行程」误当成节点动作；
/// 仍复用相同的忙碌互斥、冲突重载与 outcome 广播约定。
class TripLifecycleActions {
  TripLifecycleActions({required this.writer, required this.reload});

  final TripWriter writer;
  final Future<void> Function() reload;

  final _isBusy = ValueNotifier<bool>(false);
  final _outcomes = StreamController<TripActionOutcome>.broadcast();

  ValueListenable<bool> get isBusy => _isBusy;
  Stream<TripActionOutcome> get outcomes => _outcomes.stream;

  Future<bool> complete({required TripPlan plan}) {
    return _run(
      (writer) =>
          writer.completeTrip(tripId: plan.id, expectedRevision: plan.revision),
      success: '行程已完成。',
    );
  }

  Future<bool> cancel({required TripPlan plan}) {
    return _run(
      (writer) =>
          writer.cancelTrip(tripId: plan.id, expectedRevision: plan.revision),
      success: '行程已取消。',
    );
  }

  Future<bool> delete({required TripPlan plan}) {
    return _run(
      (writer) =>
          writer.deleteTrip(tripId: plan.id, expectedRevision: plan.revision),
      success: '行程已删除。',
      reloadAfterWrite: false,
    );
  }

  Future<bool> _run(
    Future<Object?> Function(TripWriter writer) write, {
    required String success,
    bool reloadAfterWrite = true,
  }) async {
    if (_isBusy.value) return false;
    _isBusy.value = true;
    try {
      await write(writer);
      if (reloadAfterWrite) await reload();
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

  void dispose() {
    _isBusy.dispose();
    _outcomes.close();
  }
}
