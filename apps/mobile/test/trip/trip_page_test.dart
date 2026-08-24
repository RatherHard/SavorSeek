import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

void main() {
  testWidgets('shows empty itinerary action when no plan exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TripPage(repository: InMemoryTripRepository())),
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

  testWidgets('未认证时展示登录引导而非错误页', (tester) async {
    // RLS 下无会话读取恒为空，这不是故障，UI 必须区别对待。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TripPage(
            repository: _UnauthenticatedRepository(),
            auth: const UnavailableAuthService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录后查看行程'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('行程暂时加载失败'), findsNothing);
  });
}

class _FailingRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan({String? tripId}) async =>
      throw Exception('offline');

  @override
  Future<List<TripSummary>> listTrips() async => throw Exception('offline');
}

class _UnauthenticatedRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan({String? tripId}) async =>
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );

  // 控制器先取列表再取详情，故未认证也须在此抛出，否则走不到登录引导分支。
  @override
  Future<List<TripSummary>> listTrips() async =>
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );
}
