import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

void main() {
  testWidgets('shows empty itinerary action when no plan exists', (
    tester,
  ) async {
    await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TripPage(repository: InMemoryTripRepository()),
          ),
        ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无行程'), findsOneWidget);
    expect(find.text('规划一段美食行程'), findsOneWidget);
  });

  testWidgets('shows map fallback and timeline for a loaded plan', (
    tester,
  ) async {
    final plan = TripPlan(
      id: 'trip-1',
      title: '杭州一日寻味',
      destination: '杭州 · 湖滨',
      days: [
        TripDay(
          date: DateTime(2026, 8, 22),
          label: '周六 · 8 月 22 日',
          stops: [
            TripStop(
              id: 'stop-1',
              title: '片儿川',
              subtitle: '午餐 · 12:00–13:00',
              startAt: DateTime(2026, 8, 22, 12),
              endAt: DateTime(2026, 8, 22, 13),
              type: TripStopType.lunch,
              isLocked: true,
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TripPage(repository: InMemoryTripRepository(plan: plan)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('杭州一日寻味'), findsOneWidget);
    expect(find.text('地图路线暂不可用'), findsOneWidget);
    expect(find.text('片儿川'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('shows retry action when repository fails', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TripPage(repository: _FailingRepository())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('行程暂时加载失败'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });
}

class _FailingRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan() async => throw Exception('offline');
}
