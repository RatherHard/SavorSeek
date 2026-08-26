import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_controller.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_repository_fakes.dart';

/// 单个行程的详情控制器。
void main() {
  TripPlan buildPlan({String id = 'trip-1'}) => TripPlan(
    id: id,
    title: '周末寻味',
    destination: '杭州',
    days: [
      TripDay(
        date: DateTime(2026, 8, 22),
        label: '周六',
        stops: [
          TripStop(
            id: 'stop-1',
            title: '片儿川',
            subtitle: '午餐',
            startAt: DateTime(2026, 8, 22, 12),
            endAt: DateTime(2026, 8, 22, 13),
            type: TripStopType.lunch,
          ),
        ],
      ),
    ],
  );

  group('TripController', () {
    test('读不到目标行程时进入 TripDetailGone 而非空态', () async {
      final controller = TripController(
        const InMemoryTripRepository(),
        tripId: 'trip-missing',
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state, isA<TripDetailGone>());
    });

    test('载入指定的行程', () async {
      final controller = TripController(
        InMemoryTripRepository(plan: buildPlan()),
        tripId: 'trip-1',
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state, isA<TripLoaded>());
      expect((controller.state as TripLoaded).plan.stopCount, 1);
    });

    test('把 tripId 透传给仓库', () async {
      final repository = _RecordingRepository(buildPlan(id: 'trip-b'));
      final controller = TripController(repository, tripId: 'trip-b');
      addTearDown(controller.dispose);

      await controller.load();

      expect(repository.requestedTripIds, ['trip-b']);
      expect((controller.state as TripLoaded).plan.id, 'trip-b');
    });

    test('暴露仓库错误供重试 UI 使用', () async {
      final controller = TripController(_FailingRepository(), tripId: 'trip-1');
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state, isA<TripError>());
      expect((controller.state as TripError).message, contains('offline'));
    });

    test('未认证错误保留 kind，供 UI 呈现登录引导', () async {
      final controller = TripController(
        _UnauthenticatedRepository(),
        tripId: 'trip-1',
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(
        (controller.state as TripError).kind,
        TripRepositoryErrorKind.unauthenticated,
      );
    });

    test('旧请求完成后不会覆盖更新一代的结果', () async {
      final repository = _DeferredRepository(buildPlan());
      final controller = TripController(repository, tripId: 'trip-1');
      addTearDown(controller.dispose);

      final firstLoad = controller.load();
      await repository.firstStarted.future;
      final secondLoad = controller.load();
      await repository.secondStarted.future;

      repository.completeSecond(buildPlan(id: 'trip-2'));
      await secondLoad;
      expect((controller.state as TripLoaded).plan.id, 'trip-2');

      repository.completeFirst(buildPlan(id: 'trip-1'));
      await firstLoad;
      expect((controller.state as TripLoaded).plan.id, 'trip-2');
    });
  });

  test('trip collections are immutable snapshots', () {
    final stop = TripStop(
      id: 'stop-1',
      title: '面馆',
      subtitle: '午餐',
      startAt: DateTime(2026, 8, 22, 12),
      endAt: DateTime(2026, 8, 22, 13),
      type: TripStopType.lunch,
    );
    final day = TripDay(
      date: DateTime(2026, 8, 22),
      label: '周六',
      stops: [stop],
    );
    final plan = TripPlan(
      id: 'trip-1',
      title: '行程',
      destination: '杭州',
      days: [day],
    );

    expect(() => plan.days.add(day), throwsUnsupportedError);
    expect(() => plan.days.first.stops.add(stop), throwsUnsupportedError);
    expect(plan.copyWith(title: '新行程').title, '新行程');
    expect(plan.title, '行程');
  });
}

class _RecordingRepository implements TripRepository {
  _RecordingRepository(this.plan);

  final TripPlan plan;
  final List<String?> requestedTripIds = [];

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    requestedTripIds.add(tripId);
    return tripId == plan.id ? plan : null;
  }

  @override
  Future<List<TripSummary>> listTrips() async => const [];
}

class _DeferredRepository implements TripRepository {
  _DeferredRepository(this.plan);

  final TripPlan plan;
  final firstStarted = Completer<void>();
  final secondStarted = Completer<void>();
  final _firstResult = Completer<TripPlan?>();
  final _secondResult = Completer<TripPlan?>();
  var _calls = 0;

  void completeFirst(TripPlan plan) => _firstResult.complete(plan);
  void completeSecond(TripPlan plan) => _secondResult.complete(plan);

  @override
  Future<TripPlan?> loadPlan({String? tripId}) {
    _calls++;
    if (_calls == 1) {
      firstStarted.complete();
      return _firstResult.future;
    }
    secondStarted.complete();
    return _secondResult.future;
  }

  @override
  Future<List<TripSummary>> listTrips() async => const [];
}

class _FailingRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan({String? tripId}) async =>
      throw const TripRepositoryException('offline');

  @override
  Future<List<TripSummary>> listTrips() async =>
      throw const TripRepositoryException('offline');
}

class _UnauthenticatedRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan({String? tripId}) async =>
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );

  @override
  Future<List<TripSummary>> listTrips() async =>
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );
}
