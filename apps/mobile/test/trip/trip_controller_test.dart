import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_controller.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

void main() {
  group('TripController', () {
    test('exposes empty state when repository has no plan', () async {
      final controller = TripController(const InMemoryTripRepository());
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state, isA<TripEmpty>());
    });

    test('exposes loaded plan from repository', () async {
      final plan = TripPlan(
        id: 'trip-1',
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
      final controller = TripController(InMemoryTripRepository(plan: plan));
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state, isA<TripLoaded>());
      expect((controller.state as TripLoaded).plan.stopCount, 1);
    });

    test('exposes repository errors for retry UI', () async {
      final controller = TripController(_FailingRepository());
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state, isA<TripError>());
      expect((controller.state as TripError).message, contains('offline'));
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

class _FailingRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan() async =>
      throw const TripRepositoryException('offline');
}
