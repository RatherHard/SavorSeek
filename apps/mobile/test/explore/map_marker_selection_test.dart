import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/explore/map_marker_selection.dart';
import 'package:savorseek/features/places/place_models.dart';

Place buildPlace({
  required String id,
  required double latitude,
  required double longitude,
  String category = '餐饮服务;中餐厅;烧烤',
  double? rating = 4.0,
}) {
  return Place(
    id: id,
    name: id,
    category: category,
    latitude: latitude,
    longitude: longitude,
    rating: rating,
    fetchedAt: DateTime(2026, 8, 28),
  );
}

MapMarkerSelectionContext context({
  double width = 360,
  double height = 640,
  double zoom = 14,
}) {
  return MapMarkerSelectionContext(
    centerLatitude: 38.914,
    centerLongitude: 121.615,
    zoom: zoom,
    width: width,
    height: height,
    metersPerPixel: webMercatorMetersPerPixel(latitude: 38.914, zoom: zoom),
    candidateIdentity: 'test-batch',
  );
}

void main() {
  test('keeps only food POIs with valid coordinates and AMap ratings', () {
    final result = selectMapMarkers(
      places: [
        buildPlace(id: 'food', latitude: 38.914, longitude: 121.615),
        buildPlace(
          id: 'sight',
          latitude: 38.914,
          longitude: 121.615,
          category: '风景名胜;公园',
        ),
        buildPlace(
          id: 'missing-rating',
          latitude: 38.914,
          longitude: 121.615,
          rating: null,
        ),
        buildPlace(
          id: 'bad-rating',
          latitude: 38.914,
          longitude: 121.615,
          rating: double.nan,
        ),
        Place(
          id: 'no-coordinate',
          name: 'no-coordinate',
          category: '餐饮服务;咖啡厅',
          rating: 5,
          fetchedAt: DateTime(2026, 8, 28),
        ),
      ],
      context: context(),
    );

    expect(result.places.map((place) => place.id), ['food']);
  });

  test('sorts by rating, then distance and id deterministically', () {
    final result = selectMapMarkers(
      places: [
        buildPlace(id: 'z', latitude: 38.920, longitude: 121.615, rating: 4),
        buildPlace(id: 'a', latitude: 38.914, longitude: 121.620, rating: 4),
        buildPlace(id: 'best', latitude: 38.914, longitude: 121.615, rating: 5),
      ],
      context: context(width: 1200, height: 1200),
    );

    expect(result.places.map((place) => place.id), ['best', 'a', 'z']);
  });

  test('deduplicates ids and keeps the highest-rated copy', () {
    final result = selectMapMarkers(
      places: [
        buildPlace(
          id: 'duplicate',
          latitude: 38.914,
          longitude: 121.615,
          rating: 3,
        ),
        buildPlace(
          id: 'duplicate',
          latitude: 38.914,
          longitude: 121.615,
          rating: 5,
        ),
      ],
      context: context(width: 1200, height: 1200),
    );

    expect(result.places.map((place) => place.id), ['duplicate']);
    expect(result.places.single.rating, 5);
  });

  test('uses a dynamic target and never exceeds max markers', () {
    final places = [
      for (var index = 0; index < 30; index++)
        buildPlace(
          id: 'p$index',
          latitude: 38.914 + (index ~/ 6 - 2) * 0.004,
          longitude: 121.615 + (index % 6 - 3) * 0.004,
          rating: 5 - index / 10,
        ),
    ];

    final narrow = selectMapMarkers(places: places, context: context());
    final wide = selectMapMarkers(
      places: places,
      context: context(width: 1200, height: 1200),
    );

    expect(narrow.places.length, lessThanOrEqualTo(wide.places.length));
    expect(wide.places.length, lessThanOrEqualTo(20));
  });

  test('is stable when candidate input order changes', () {
    final first = selectMapMarkers(
      places: [
        buildPlace(id: 'b', latitude: 38.914, longitude: 121.616),
        buildPlace(id: 'a', latitude: 38.914, longitude: 121.614),
      ],
      context: context(width: 1200, height: 1200),
    );
    final second = selectMapMarkers(
      places: [
        buildPlace(id: 'a', latitude: 38.914, longitude: 121.614),
        buildPlace(id: 'b', latitude: 38.914, longitude: 121.616),
      ],
      context: context(width: 1200, height: 1200),
    );

    expect(
      second.places.map((place) => place.id),
      first.places.map((place) => place.id),
    );
    expect(second.selectionKey, first.selectionKey);
  });

  test('rejects invalid dimensions and zoom without throwing', () {
    expect(
      selectMapMarkers(
        places: [buildPlace(id: 'p', latitude: 38.914, longitude: 121.615)],
        context: context(width: 0),
      ).places,
      isEmpty,
    );
    expect(
      selectMapMarkers(
        places: [buildPlace(id: 'p', latitude: 38.914, longitude: 121.615)],
        context: context(zoom: double.nan),
      ).places,
      isEmpty,
    );
  });
}
