import 'dart:convert';

import 'package:flutter/foundation.dart';

const placeSearchContractVersion = 'places-filter-v1';

/// A rectangular search range in longitude/latitude degrees.
@immutable
class PlaceSearchBounds {
  const PlaceSearchBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  }) : assert(south >= -90 && south <= 90),
       assert(north >= -90 && north <= 90),
       assert(south <= north),
       assert(west >= -180 && west <= 180),
       assert(east >= -180 && east <= 180);

  final double south;
  final double west;
  final double north;
  final double east;

  bool get crossesAntimeridian => west > east;

  bool containsLongitude(double longitude) {
    if (crossesAntimeridian) {
      return longitude >= west || longitude <= east;
    }
    return longitude >= west && longitude <= east;
  }

  bool contains({required double latitude, required double longitude}) =>
      latitude >= south && latitude <= north && containsLongitude(longitude);

  Map<String, double> toJson() => {
    'south': _round(south),
    'west': _round(west),
    'north': _round(north),
    'east': _round(east),
  };

  String get canonicalKey => jsonEncode(toJson());

  static double _round(double value) =>
      (value * 1000000).roundToDouble() / 1000000;
}

/// Values that can be obtained from a provider without inventing facts.
@immutable
class PlaceSearchFilters {
  const PlaceSearchFilters({
    this.cuisineTags = const [],
    this.minPriceLevel,
    this.maxPriceLevel,
    this.maxDistanceMeters,
    this.openNow,
    this.minRating,
  }) : assert(
         minPriceLevel == null || (minPriceLevel >= 1 && minPriceLevel <= 4),
       ),
       assert(
         maxPriceLevel == null || (maxPriceLevel >= 1 && maxPriceLevel <= 4),
       ),
       assert(
         minPriceLevel == null ||
             maxPriceLevel == null ||
             minPriceLevel <= maxPriceLevel,
       ),
       assert(maxDistanceMeters == null || maxDistanceMeters > 0),
       assert(minRating == null || (minRating >= 0 && minRating <= 5));

  final List<String> cuisineTags;
  final int? minPriceLevel;
  final int? maxPriceLevel;
  final int? maxDistanceMeters;
  final bool? openNow;
  final double? minRating;

  bool get hasDistanceFilter => maxDistanceMeters != null;

  Map<String, dynamic> toJson() => {
    'cuisine_tags': _normalizedTags,
    'min_price_level': minPriceLevel,
    'max_price_level': maxPriceLevel,
    'max_distance_meters': maxDistanceMeters,
    'open_now': openNow,
    'min_rating': minRating == null
        ? null
        : (minRating! * 10).roundToDouble() / 10,
  };

  List<String> get _normalizedTags {
    final tags = cuisineTags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    tags.sort();
    return List.unmodifiable(tags);
  }
}

/// Optional distance reference point. It is query context, not place data.
@immutable
class PlaceSearchOrigin {
  const PlaceSearchOrigin({required this.latitude, required this.longitude})
    : assert(latitude >= -90 && latitude <= 90),
      assert(longitude >= -180 && longitude <= 180);

  final double latitude;
  final double longitude;

  Map<String, double> toJson() => {
    'latitude': _round(latitude),
    'longitude': _round(longitude),
  };

  static double _round(double value) =>
      (value * 100000).roundToDouble() / 100000;
}

@immutable
class PlaceSearchQuery {
  PlaceSearchQuery({
    required this.bounds,
    this.keywords,
    this.city,
    this.origin,
    this.filters = const PlaceSearchFilters(),
    this.limit = 100,
    this.cursor,
  }) {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 100');
    }
    if (filters.hasDistanceFilter && origin == null) {
      throw ArgumentError('distance filtering requires an origin');
    }
  }

  final PlaceSearchBounds bounds;
  final String? keywords;
  final String? city;
  final PlaceSearchOrigin? origin;
  final PlaceSearchFilters filters;
  final int limit;
  final String? cursor;

  Map<String, dynamic> toJson() => {
    'kind': 'bounds',
    'contract_version': placeSearchContractVersion,
    'bounds': bounds.toJson(),
    if (_trimmed(keywords) != null) 'keywords': _trimmed(keywords),
    if (_trimmed(city) != null) 'city': _trimmed(city),
    if (origin != null) 'origin': origin!.toJson(),
    'filters': filters.toJson(),
    'limit': limit,
    if (cursor != null && cursor!.isNotEmpty) 'cursor': cursor,
  };

  String get canonicalKey => jsonEncode(toJson());

  static String? _trimmed(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
