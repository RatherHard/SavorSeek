import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/explore/map_viewport.dart';

void main() {
  test('returns a conservative query for a normal camera', () {
    final query = buildMapViewportQuery(
      latitude: 38.914003,
      longitude: 121.614682,
      zoom: 13,
      width: 400,
      height: 800,
    );

    expect(query, isNotNull);
    expect(query!.center.latitude, 38.914);
    expect(query.center.longitude, 121.6147);
    expect(query.radiusMeters, greaterThan(1));
    expect(query.radiusMeters, lessThanOrEqualTo(50000));
  });

  test('larger zoom produces a smaller radius', () {
    final wide = buildMapViewportQuery(latitude: 38, longitude: 121, zoom: 10)!;
    final close = buildMapViewportQuery(
      latitude: 38,
      longitude: 121,
      zoom: 15,
    )!;

    expect(close.radiusMeters, lessThan(wide.radiusMeters));
  });

  test('caps an extremely wide viewport at the provider maximum', () {
    final query = buildMapViewportQuery(
      latitude: 0,
      longitude: 0,
      zoom: 0,
      width: 10000,
      height: 10000,
    )!;

    expect(query.radiusMeters, 50000);
  });

  test('rejects invalid camera and dimensions', () {
    expect(
      buildMapViewportQuery(latitude: double.nan, longitude: 121, zoom: 13),
      isNull,
    );
    expect(
      buildMapViewportQuery(latitude: 91, longitude: 121, zoom: 13),
      isNull,
    );
    expect(
      buildMapViewportQuery(latitude: 38, longitude: 121, zoom: 13, width: 0),
      isNull,
    );
  });

  test('normalizes nearby camera values into the same query key', () {
    final first = buildMapViewportQuery(
      latitude: 38.91401,
      longitude: 121.61465,
      zoom: 13.0,
    )!;
    final second = buildMapViewportQuery(
      latitude: 38.91402,
      longitude: 121.61468,
      zoom: 13.01,
    )!;

    expect(second.key, first.key);
  });
}
