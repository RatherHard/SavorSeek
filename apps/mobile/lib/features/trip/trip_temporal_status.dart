import 'package:flutter/material.dart';

import 'trip_models.dart';
import 'trip_time_zone.dart';

enum TripDisplayStatus { upcoming, inProgress, completed, cancelled }

TripDisplayStatus resolveTripDisplayStatus({
  required TripStatus persistedStatus,
  required DateTime startDate,
  required DateTime endDate,
  required String timezone,
  required DateTime now,
}) {
  if (persistedStatus == TripStatus.cancelled) {
    return TripDisplayStatus.cancelled;
  }
  if (persistedStatus == TripStatus.completed) {
    return TripDisplayStatus.completed;
  }

  final localNow = TripTimeZone.toWallClock(
    timezone: timezone,
    instant: now.toUtc(),
  );
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final start = DateTime(startDate.year, startDate.month, startDate.day);
  final end = DateTime(endDate.year, endDate.month, endDate.day);
  if (today.isBefore(start)) return TripDisplayStatus.upcoming;
  if (today.isAfter(end)) return TripDisplayStatus.completed;
  return TripDisplayStatus.inProgress;
}

String tripDisplayStatusLabel(TripDisplayStatus status) {
  return switch (status) {
    TripDisplayStatus.upcoming => '待出行',
    TripDisplayStatus.inProgress => '进行中',
    TripDisplayStatus.completed => '已完成',
    TripDisplayStatus.cancelled => '已取消',
  };
}

Color tripDisplayStatusColor(BuildContext context, TripDisplayStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    TripDisplayStatus.upcoming => scheme.primary,
    TripDisplayStatus.inProgress => scheme.primary,
    TripDisplayStatus.completed => scheme.tertiary,
    TripDisplayStatus.cancelled => scheme.error,
  };
}
