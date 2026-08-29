import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/places/place_search_query.dart';

void main() {
  test('normalizes filters and produces a stable canonical key', () {
    final first = PlaceSearchQuery(
      bounds: const PlaceSearchBounds(
        south: 38.8,
        west: 121.5,
        north: 39.0,
        east: 121.7,
      ),
      filters: const PlaceSearchFilters(
        cuisineTags: ['烧烤', '川菜'],
        minPriceLevel: 1,
        maxPriceLevel: 3,
        maxDistanceMeters: 2500,
        openNow: true,
        minRating: 4,
      ),
      origin: const PlaceSearchOrigin(latitude: 38.9, longitude: 121.6),
    );
    final second = PlaceSearchQuery(
      bounds: const PlaceSearchBounds(
        south: 38.8000001,
        west: 121.5000001,
        north: 39.0000001,
        east: 121.7000001,
      ),
      filters: const PlaceSearchFilters(
        cuisineTags: ['川菜', '烧烤', '烧烤'],
        minPriceLevel: 1,
        maxPriceLevel: 3,
        maxDistanceMeters: 2500,
        openNow: true,
        minRating: 4,
      ),
      origin: const PlaceSearchOrigin(latitude: 38.9, longitude: 121.6),
    );

    expect(first.canonicalKey, second.canonicalKey);
    expect(first.toJson()['filters'], isA<Map<String, dynamic>>());
  });

  test('rejects a distance filter without an origin', () {
    expect(
      () => PlaceSearchQuery(
        bounds: const PlaceSearchBounds(south: 0, west: 0, north: 1, east: 1),
        filters: const PlaceSearchFilters(maxDistanceMeters: 1000),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('recognizes antimeridian bounds', () {
    const bounds = PlaceSearchBounds(
      south: -1,
      west: 170,
      north: 1,
      east: -170,
    );
    expect(bounds.crossesAntimeridian, isTrue);
    expect(bounds.containsLongitude(179), isTrue);
    expect(bounds.containsLongitude(-179), isTrue);
    expect(bounds.containsLongitude(0), isFalse);
  });
}
