import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_temporal_status.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  const timezone = 'Asia/Tokyo';
  final start = DateTime(2026, 9, 1);
  final end = DateTime(2026, 9, 3);

  test('uses trip timezone rather than device or UTC date', () {
    final status = resolveTripDisplayStatus(
      persistedStatus: TripStatus.confirmed,
      startDate: start,
      endDate: end,
      timezone: timezone,
      // 2026-08-31 16:30 UTC is 2026-09-01 01:30 in Tokyo.
      now: DateTime.utc(2026, 8, 31, 16, 30),
    );

    expect(status, TripDisplayStatus.inProgress);
  });

  test('returns upcoming before the local start date', () {
    final status = resolveTripDisplayStatus(
      persistedStatus: TripStatus.draft,
      startDate: start,
      endDate: end,
      timezone: timezone,
      now: DateTime.utc(2026, 8, 31, 14),
    );

    expect(status, TripDisplayStatus.upcoming);
  });

  test('returns completed after the local end date without persistence', () {
    final status = resolveTripDisplayStatus(
      persistedStatus: TripStatus.confirmed,
      startDate: start,
      endDate: end,
      timezone: timezone,
      now: DateTime.utc(2026, 9, 3, 15),
    );

    expect(status, TripDisplayStatus.completed);
  });

  test('persisted terminal statuses take precedence over date projection', () {
    final now = DateTime.utc(2026, 9, 10);

    expect(
      resolveTripDisplayStatus(
        persistedStatus: TripStatus.cancelled,
        startDate: start,
        endDate: end,
        timezone: timezone,
        now: now,
      ),
      TripDisplayStatus.cancelled,
    );
    expect(
      resolveTripDisplayStatus(
        persistedStatus: TripStatus.completed,
        startDate: start,
        endDate: end,
        timezone: timezone,
        now: now,
      ),
      TripDisplayStatus.completed,
    );
  });

  test('includes both boundaries in the in-progress date range', () {
    expect(
      resolveTripDisplayStatus(
        persistedStatus: TripStatus.inProgress,
        startDate: start,
        endDate: end,
        timezone: timezone,
        now: DateTime.utc(2026, 9, 1, 12),
      ),
      TripDisplayStatus.inProgress,
    );
    expect(
      resolveTripDisplayStatus(
        persistedStatus: TripStatus.inProgress,
        startDate: start,
        endDate: end,
        timezone: timezone,
        now: DateTime.utc(2026, 9, 3, 12),
      ),
      TripDisplayStatus.inProgress,
    );
  });
}
