import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/places/place_models.dart';

Map<String, dynamic> placeJson(Object? rating) => {
  'id': 'p1',
  'name': '店铺',
  'rating': rating,
  'fetched_at': '2026-08-28T00:00:00Z',
};

void main() {
  test('parses numeric and string ratings from the provider response', () {
    expect(Place.fromJson(placeJson(4.6)).rating, 4.6);
    expect(Place.fromJson(placeJson('4.6')).rating, 4.6);
  });

  test('keeps missing or malformed ratings nullable', () {
    for (final value in [null, '', 'unknown', true, <Object>[]]) {
      expect(Place.fromJson(placeJson(value)).rating, isNull);
    }
  });

  test('validates the inclusive AMap rating range', () {
    expect(Place.fromJson(placeJson(0)).hasValidRating, isTrue);
    expect(Place.fromJson(placeJson(5)).hasValidRating, isTrue);
    expect(Place.fromJson(placeJson(-0.1)).hasValidRating, isFalse);
    expect(Place.fromJson(placeJson(5.1)).hasValidRating, isFalse);
  });

  test('rejects non-finite ratings constructed outside JSON parsing', () {
    final base = Place.fromJson(placeJson(4));
    expect(
      Place(
        id: base.id,
        name: base.name,
        rating: double.nan,
        fetchedAt: base.fetchedAt,
      ).hasValidRating,
      isFalse,
    );
    expect(
      Place(
        id: base.id,
        name: base.name,
        rating: double.infinity,
        fetchedAt: base.fetchedAt,
      ).hasValidRating,
      isFalse,
    );
  });
}
