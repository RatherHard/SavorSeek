import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:savorseek/app/config/supabase_config.dart';

import 'trip_models.dart';
import 'trip_repository.dart';

/// 内存仓库，供 Widget 测试与离线演示使用。
class InMemoryTripRepository implements TripRepository {
  const InMemoryTripRepository({this.plan});

  final TripPlan? plan;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    if (tripId != null && tripId != plan?.id) return null;
    return plan;
  }

  @override
  Future<List<TripSummary>> listTrips() async {
    final current = plan;
    if (current == null) return const [];
    return [
      TripSummary(
        id: current.id,
        title: current.title,
        startDate: current.days.isEmpty
            ? DateTime.now()
            : current.days.first.date,
        endDate: current.days.isEmpty ? DateTime.now() : current.days.last.date,
        timezone: current.timezone,
        status: current.status,
        updatedAt: current.updatedAt,
      ),
    ];
  }
}

/// 后端不可用时的占位仓库。
class UnavailableTripRepository implements TripRepository {
  const UnavailableTripRepository([this.message]);

  final String? message;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    throw TripRepositoryException(message ?? SupabaseConfig.missingMessage);
  }

  @override
  Future<List<TripSummary>> listTrips() async {
    throw TripRepositoryException(message ?? SupabaseConfig.missingMessage);
  }
}

/// 演示数据仓库。
class DemoTripRepository implements TripRepository {
  const DemoTripRepository();

  @override
  Future<List<TripSummary>> listTrips() async {
    final plan = await loadPlan();
    if (plan == null) return const [];
    return [
      TripSummary(
        id: plan.id,
        title: plan.title,
        startDate: plan.days.first.date,
        endDate: plan.days.last.date,
        timezone: plan.timezone,
        status: plan.status,
        updatedAt: plan.updatedAt,
      ),
    ];
  }

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    if (tripId != null && tripId != 'demo-shanghai-food-day') return null;
    final day = DateTime(2026, 8, 22);
    return TripPlan(
      id: 'demo-shanghai-food-day',
      title: '上海一日寻味',
      destination: '上海 · 徐汇与静安',
      mapState: TripMapState.unavailable,
      updatedAt: DateTime(2026, 8, 21, 18),
      days: [
        TripDay(
          date: day,
          label: '周六 · 8 月 22 日',
          stops: [
            TripStop(
              id: 'breakfast',
              title: '老城隍庙小笼',
              subtitle: '早餐 · 08:30–09:30',
              startAt: DateTime(2026, 8, 22, 8, 30),
              endAt: DateTime(2026, 8, 22, 9, 30),
              type: TripStopType.breakfast,
              note: '建议先取号，再沿福佑路慢慢逛过去。',
            ),
            TripStop(
              id: 'lunch',
              title: '本帮菜午餐',
              subtitle: '午餐 · 12:00–13:30',
              startAt: DateTime(2026, 8, 22, 12),
              endAt: DateTime(2026, 8, 22, 13, 30),
              type: TripStopType.lunch,
              isLocked: true,
              note: '已锁定：保留给第一次来上海的本帮菜体验。',
            ),
            TripStop(
              id: 'snack',
              title: '安福路咖啡与甜点',
              subtitle: '下午茶 · 15:00–16:30',
              startAt: DateTime(2026, 8, 22, 15),
              endAt: DateTime(2026, 8, 22, 16, 30),
              type: TripStopType.afternoonTea,
              note: '留出步行时间，按现场排队情况灵活调整。',
            ),
            TripStop(
              id: 'dinner',
              title: '夜宵：生煎与排骨年糕',
              subtitle: '晚餐 · 18:30–20:00',
              startAt: DateTime(2026, 8, 22, 18, 30),
              endAt: DateTime(2026, 8, 22, 20),
              type: TripStopType.dinner,
            ),
          ],
        ),
      ],
    );
  }
}

@immutable
class TripPlanSummary {
  const TripPlanSummary({required this.plan});

  final TripPlan plan;

  int get stopCount => plan.stopCount;

  Duration get plannedDuration {
    if (plan.days.isEmpty || plan.days.first.stops.isEmpty) {
      return Duration.zero;
    }
    final stops = plan.days.expand((day) => day.stops).toList(growable: false);
    final start = stops
        .map((stop) => stop.startAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final end = stops
        .map((stop) => stop.endAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    return end.difference(start);
  }

  double get dayCount => math.max(plan.days.length, 1).toDouble();
}
