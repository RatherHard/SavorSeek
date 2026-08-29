import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/explore/map_marker_selection.dart';
import 'package:savorseek/features/places/place_models.dart';

Place buildPlace({
  required String id,
  double? latitude = 38.914,
  double? longitude = 121.615,
  String? category = '餐饮服务;中餐厅;烧烤',
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
  test('filters drawer places by food category while preserving order', () {
    final unratedFood = buildPlace(
      id: 'unrated-food',
      latitude: 38.914,
      longitude: 121.615,
      rating: null,
    );
    final result = filterFoodPlaces([
      buildPlace(id: 'food-a', category: '餐饮服务；中餐厅'),
      buildPlace(id: 'sight', category: '风景名胜;公园'),
      unratedFood,
      buildPlace(id: 'unknown', category: null),
    ]);

    expect(result.map((place) => place.id), ['food-a', 'unrated-food']);
    expect(() => result.add(buildPlace(id: 'later')), throwsUnsupportedError);
  });

  test('keeps food places without coordinates in drawer projection', () {
    final place = Place(
      id: 'food-without-coordinate',
      name: '待补坐标的小店',
      category: '餐饮服务;小吃',
      rating: 4,
      fetchedAt: DateTime(2026, 8, 28),
    );

    expect(filterFoodPlaces([place]), [place]);
  });

  test('rejects unknown and empty categories in drawer projection', () {
    final result = filterFoodPlaces([
      buildPlace(id: 'empty', category: ''),
      buildPlace(id: 'unknown', category: '购物服务;商场'),
      buildPlace(id: 'food', category: ' 餐饮服务 ; 咖啡厅 '),
    ]);

    expect(result.map((place) => place.id), ['food']);
  });

  test('keeps food places without a rating when coordinates are valid', () {
    final result = selectMapMarkers(
      places: [
        buildPlace(
          id: 'unrated',
          rating: null,
          latitude: 38.914,
          longitude: 121.615,
        ),
        buildPlace(
          id: 'invalid-rating',
          rating: double.nan,
          latitude: 38.914,
          longitude: 121.616,
        ),
      ],
      context: context(width: 1200, height: 1200),
    );

    expect(result.places.map((place) => place.id), [
      'unrated',
      'invalid-rating',
    ]);
  });

  test('keeps only food places with valid coordinates', () {
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
          longitude: 121.616,
          rating: null,
        ),
        buildPlace(
          id: 'bad-rating',
          latitude: 38.914,
          longitude: 121.617,
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

    expect(result.places.map((place) => place.id), [
      'food',
      'missing-rating',
      'bad-rating',
    ]);
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

  test(
    'distributes markers across visible regions before filling by rating',
    () {
      final clustered = [
        buildPlace(
          id: 'cluster-1',
          rating: 5,
          latitude: 38.914,
          longitude: 121.615,
        ),
        buildPlace(
          id: 'cluster-2',
          rating: 4.9,
          latitude: 38.915,
          longitude: 121.615,
        ),
        buildPlace(
          id: 'cluster-3',
          rating: 4.8,
          latitude: 38.916,
          longitude: 121.615,
        ),
        buildPlace(
          id: 'cluster-4',
          rating: 4.7,
          latitude: 38.917,
          longitude: 121.615,
        ),
      ];
      final outer = [
        buildPlace(
          id: 'north-west',
          rating: 3,
          latitude: 38.926,
          longitude: 121.600,
        ),
        buildPlace(
          id: 'north-east',
          rating: 3,
          latitude: 38.926,
          longitude: 121.630,
        ),
        buildPlace(
          id: 'south-west',
          rating: 3,
          latitude: 38.902,
          longitude: 121.600,
        ),
        buildPlace(
          id: 'south-east',
          rating: 3,
          latitude: 38.902,
          longitude: 121.630,
        ),
      ];

      final result = selectMapMarkers(
        places: [...clustered, ...outer],
        context: context(),
        config: const MapMarkerSelectionConfig(
          markerFootprintPx: 20,
          markerGapPx: 4,
          minMarkers: 4,
          maxMarkers: 4,
        ),
      );

      final selectedIds = result.places.map((place) => place.id).toSet();
      expect(
        selectedIds.intersection(outer.map((place) => place.id).toSet()).length,
        greaterThanOrEqualTo(3),
      );
      expect(selectedIds, isNot(contains('cluster-4')));
    },
  );

  test('uses a smaller safe fallback spacing for dense places', () {
    final result = selectMapMarkers(
      places: [
        buildPlace(id: 'a', rating: 5, latitude: 38.914, longitude: 121.615),
        buildPlace(id: 'b', rating: 4, latitude: 38.914, longitude: 121.6155),
        buildPlace(id: 'c', rating: 3, latitude: 38.914, longitude: 121.616),
      ],
      context: context(width: 1200, height: 1200),
      config: const MapMarkerSelectionConfig(
        markerFootprintPx: 20,
        markerGapPx: 4,
        minMarkers: 3,
        maxMarkers: 3,
      ),
    );

    expect(result.places.map((place) => place.id), ['a', 'c']);
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
