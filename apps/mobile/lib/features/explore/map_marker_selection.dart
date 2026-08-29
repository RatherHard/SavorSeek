import 'dart:math' as math;

import 'package:savorseek/features/places/place_models.dart';

const _selectionVersion = 'marker-selection-v3';
const _earthMetersPerDegreeLatitude = 110540.0;
const _earthMetersPerDegreeLongitude = 111320.0;

const _foodCategories = <String>{
  '餐饮服务',
  '餐饮',
  '中餐厅',
  '西餐厅',
  '外国餐厅',
  '快餐厅',
  '特色餐饮',
  '火锅',
  '烧烤',
  '小吃',
  '咖啡厅',
  '茶饮',
  '甜品',
  '糕点',
  '面包',
  '料理',
};

class MapMarkerSelectionContext {
  const MapMarkerSelectionContext({
    required this.centerLatitude,
    required this.centerLongitude,
    required this.zoom,
    required this.width,
    required this.height,
    required this.metersPerPixel,
    required this.candidateIdentity,
    this.queryRadiusMeters = 3000,
  });

  final double centerLatitude;
  final double centerLongitude;
  final double zoom;
  final double width;
  final double height;
  final double metersPerPixel;
  final String candidateIdentity;
  final double queryRadiusMeters;
}

class MapMarkerSelectionConfig {
  const MapMarkerSelectionConfig({
    this.markerFootprintPx = 40,
    this.markerGapPx = 8,
    this.viewportPaddingPx = 20,
    this.minMarkers = 4,
    this.maxMarkers = 20,
    this.minDensityFactor = 0.5,
  });

  final double markerFootprintPx;
  final double markerGapPx;
  final double viewportPaddingPx;
  final int minMarkers;
  final int maxMarkers;
  final double minDensityFactor;
}

class MapMarkerSelectionResult {
  const MapMarkerSelectionResult({
    required this.places,
    required this.targetCount,
    required this.eligibleCount,
    required this.selectionKey,
    required this.isValid,
  });

  final List<Place> places;
  final int targetCount;
  final int eligibleCount;
  final String selectionKey;
  final bool isValid;
}

bool isFoodCategory(String? category) {
  final value = category;
  if (value == null) return false;
  final levels = value
      .replaceAll('；', ';')
      .split(';')
      .map((part) => part.trim().toLowerCase())
      .where((part) => part.isNotEmpty);
  return levels.any(_foodCategories.contains);
}

/// Returns the food-only projection used by the Explore results drawer.
///
/// This intentionally checks only the category. Coordinates and ratings are
/// marker-specific requirements; a food place without either is still useful
/// in the results list and can be opened for details.
List<Place> filterFoodPlaces(Iterable<Place> places) {
  return List.unmodifiable(
    places.where((place) => isFoodCategory(place.category)),
  );
}

bool isValidAmapRating(double? rating) =>
    rating != null && rating.isFinite && rating >= 0 && rating <= 5;

double webMercatorMetersPerPixel({
  required double latitude,
  required double zoom,
}) {
  final clampedLatitude = latitude.clamp(-85.0, 85.0).toDouble();
  return 156543.03392 *
      math.cos(clampedLatitude * math.pi / 180) /
      math.pow(2, zoom);
}

MapMarkerSelectionResult selectMapMarkers({
  required List<Place> places,
  required MapMarkerSelectionContext context,
  MapMarkerSelectionConfig config = const MapMarkerSelectionConfig(),
}) {
  final key = _selectionKey(places, context, config);
  if (!_isValidContext(context) || !_isValidConfig(config)) {
    return MapMarkerSelectionResult(
      places: const [],
      targetCount: 0,
      eligibleCount: 0,
      selectionKey: key,
      isValid: false,
    );
  }

  final eligible = places.where(_isEligible).toList()
    ..sort((a, b) => _compare(a, b, context));
  final deduplicated = <String, Place>{};
  for (final place in eligible) {
    final id = place.id.trim();
    final existing = deduplicated[id];
    if (existing == null || _compare(place, existing, context) < 0) {
      deduplicated[id] = place;
    }
  }
  final normalized = deduplicated.values.toList()
    ..sort((a, b) => _compare(a, b, context));
  final visible = normalized
      .where((place) => _isInEstimatedViewport(place, context, config))
      .toList();
  final target = _targetCount(context, config, visible.length);
  final selected = _selectAcrossViewport(
    visible: visible,
    target: target,
    context: context,
    config: config,
  );

  return MapMarkerSelectionResult(
    places: List.unmodifiable(selected),
    targetCount: target,
    eligibleCount: normalized.length,
    selectionKey: key,
    isValid: true,
  );
}

List<Place> _selectAcrossViewport({
  required List<Place> visible,
  required int target,
  required MapMarkerSelectionContext context,
  required MapMarkerSelectionConfig config,
}) {
  if (target == 0) return const <Place>[];

  final grid = _buildSelectionGrid(target, context, config);
  final byCell = <String, List<Place>>{};
  for (final place in visible) {
    final point = _project(place, context);
    final cell = _cellFor(point, context, grid);
    (byCell[cell] ??= <Place>[]).add(place);
  }

  final cells = byCell.keys.toList()..sort(_compareCellKeys);
  final selected = <Place>[];
  final selectedIds = <String>{};
  for (final cell in cells) {
    if (selected.length >= target) break;
    final candidates = byCell[cell]!..sort((a, b) => _compare(a, b, context));
    Place? place;
    for (final candidate in candidates) {
      if (!_tooClose(_project(candidate, context), selected, context, config)) {
        place = candidate;
        break;
      }
    }
    if (place == null) continue;
    selected.add(place);
    selectedIds.add(place.id.trim());
  }

  final remaining =
      visible.where((place) => !selectedIds.contains(place.id.trim())).toList()
        ..sort((a, b) => _compare(a, b, context));
  for (final place in remaining) {
    if (selected.length >= target) break;
    if (_tooClose(_project(place, context), selected, context, config)) {
      continue;
    }
    selected.add(place);
  }

  if (selected.length < target) {
    final fallbackSpacing = math.max(
      8.0,
      (config.markerFootprintPx + config.markerGapPx) * 0.2,
    );
    for (final place in remaining) {
      if (selected.length >= target) break;
      if (selected.any((selectedPlace) => selectedPlace.id == place.id)) {
        continue;
      }
      if (_tooClose(
        _project(place, context),
        selected,
        context,
        config,
        spacingPx: fallbackSpacing,
      )) {
        continue;
      }
      selected.add(place);
    }
  }
  return selected;
}

({int columns, int rows}) _buildSelectionGrid(
  int target,
  MapMarkerSelectionContext context,
  MapMarkerSelectionConfig config,
) {
  final cellSize = config.markerFootprintPx + config.markerGapPx;
  final maxColumns = math.max(1, (context.width / cellSize).floor());
  final maxRows = math.max(1, (context.height / cellSize).floor());
  final aspect = context.width / context.height;
  final columns = math.min(
    maxColumns,
    math.max(1, math.sqrt(target * aspect).round()),
  );
  final rows = math.min(maxRows, math.max(1, (target / columns).ceil()));
  return (columns: columns, rows: rows);
}

String _cellFor(
  (double, double) point,
  MapMarkerSelectionContext context,
  ({int columns, int rows}) grid,
) {
  final x = ((point.$1 + context.width / 2) / context.width * grid.columns)
      .floor()
      .clamp(0, grid.columns - 1);
  final y = ((point.$2 + context.height / 2) / context.height * grid.rows)
      .floor()
      .clamp(0, grid.rows - 1);
  return '$y:$x';
}

int _compareCellKeys(String a, String b) {
  final aParts = a.split(':').map(int.parse).toList();
  final bParts = b.split(':').map(int.parse).toList();
  final row = aParts[0].compareTo(bParts[0]);
  return row == 0 ? aParts[1].compareTo(bParts[1]) : row;
}

bool _isEligible(Place place) =>
    place.id.trim().isNotEmpty &&
    isFoodCategory(place.category) &&
    place.latitude != null &&
    place.longitude != null &&
    place.latitude!.isFinite &&
    place.longitude!.isFinite &&
    place.latitude! >= -90 &&
    place.latitude! <= 90 &&
    place.longitude! >= -180 &&
    place.longitude! <= 180;

int _compare(Place a, Place b, MapMarkerSelectionContext context) {
  final rating = _ratingPriority(b).compareTo(_ratingPriority(a));
  if (rating != 0) return rating;
  final distance = _distanceSquared(
    a,
    context,
  ).compareTo(_distanceSquared(b, context));
  if (distance != 0) return distance;
  final id = a.id.trim().compareTo(b.id.trim());
  if (id != 0) return id;
  final longitude = a.longitude!.compareTo(b.longitude!);
  if (longitude != 0) return longitude;
  final latitude = a.latitude!.compareTo(b.latitude!);
  if (latitude != 0) return latitude;
  final name = a.name.trim().compareTo(b.name.trim());
  if (name != 0) return name;
  final category = (a.category ?? '').trim().compareTo(
    (b.category ?? '').trim(),
  );
  if (category != 0) return category;
  final address = (a.address ?? '').trim().compareTo((b.address ?? '').trim());
  if (address != 0) return address;
  return a.fetchedAt.compareTo(b.fetchedAt);
}

double _ratingPriority(Place place) {
  final rating = place.rating;
  return isValidAmapRating(rating) ? rating! : -1;
}

double _distanceSquared(Place place, MapMarkerSelectionContext context) {
  final point = _project(place, context);
  return point.$1 * point.$1 + point.$2 * point.$2;
}

(double, double) _project(Place place, MapMarkerSelectionContext context) {
  var longitudeDelta = place.longitude! - context.centerLongitude;
  if (longitudeDelta > 180) longitudeDelta -= 360;
  if (longitudeDelta < -180) longitudeDelta += 360;
  final latitude = context.centerLatitude.clamp(-85.0, 85.0).toDouble();
  final xMeters =
      longitudeDelta *
      _earthMetersPerDegreeLongitude *
      math.cos(latitude * math.pi / 180);
  final yMeters =
      (place.latitude! - context.centerLatitude) *
      _earthMetersPerDegreeLatitude;
  return (xMeters / context.metersPerPixel, yMeters / context.metersPerPixel);
}

bool _isInEstimatedViewport(
  Place place,
  MapMarkerSelectionContext context,
  MapMarkerSelectionConfig config,
) {
  final point = _project(place, context);
  final halfWidth = context.width / 2 + config.viewportPaddingPx;
  final halfHeight = context.height / 2 + config.viewportPaddingPx;
  return point.$1.abs() <= halfWidth && point.$2.abs() <= halfHeight;
}

bool _tooClose(
  (double, double) point,
  List<Place> selected,
  MapMarkerSelectionContext context,
  MapMarkerSelectionConfig config, {
  double? spacingPx,
}) {
  final spacing = spacingPx ?? config.markerFootprintPx + config.markerGapPx;
  final spacingSquared = spacing * spacing;
  for (final place in selected) {
    final other = _project(place, context);
    final dx = point.$1 - other.$1;
    final dy = point.$2 - other.$2;
    if (dx * dx + dy * dy < spacingSquared) return true;
  }
  return false;
}

int _targetCount(
  MapMarkerSelectionContext context,
  MapMarkerSelectionConfig config,
  int eligibleCount,
) {
  final cellSize = config.markerFootprintPx + config.markerGapPx;
  final columns = math.max(1, (context.width / cellSize).floor());
  final rows = math.max(1, (context.height / cellSize).floor());
  final zoomFactor = ((context.zoom - 10) / 8).clamp(0.0, 1.0).toDouble();
  final radiusFactor = (30000 / context.queryRadiusMeters)
      .clamp(0.0, 1.0)
      .toDouble();
  final scaleFactor = (500 / context.metersPerPixel).clamp(0.0, 1.0).toDouble();
  final density = math.max(
    config.minDensityFactor,
    (zoomFactor + radiusFactor + scaleFactor) / 3,
  );
  final capacity = (columns * rows * density).floor();
  return math.min(eligibleCount, math.min(config.maxMarkers, capacity));
}

bool _isValidContext(MapMarkerSelectionContext context) =>
    context.centerLatitude.isFinite &&
    context.centerLongitude.isFinite &&
    context.centerLatitude >= -90 &&
    context.centerLatitude <= 90 &&
    context.centerLongitude >= -180 &&
    context.centerLongitude <= 180 &&
    context.zoom.isFinite &&
    context.zoom >= 0 &&
    context.zoom <= 24 &&
    context.width.isFinite &&
    context.width > 0 &&
    context.height.isFinite &&
    context.height > 0 &&
    context.metersPerPixel.isFinite &&
    context.metersPerPixel > 0 &&
    context.queryRadiusMeters.isFinite &&
    context.queryRadiusMeters > 0;

bool _isValidConfig(MapMarkerSelectionConfig config) =>
    config.markerFootprintPx.isFinite &&
    config.markerFootprintPx > 0 &&
    config.markerGapPx.isFinite &&
    config.markerGapPx > 0 &&
    config.viewportPaddingPx.isFinite &&
    config.viewportPaddingPx >= 0 &&
    config.minMarkers >= 0 &&
    config.maxMarkers >= config.minMarkers &&
    config.minDensityFactor.isFinite &&
    config.minDensityFactor > 0 &&
    config.minDensityFactor <= 1;

String _selectionKey(
  List<Place> places,
  MapMarkerSelectionContext context,
  MapMarkerSelectionConfig config,
) {
  final fingerprint =
      places
          .map(
            (place) =>
                '${place.id.trim()}:${place.rating}:${place.latitude}:'
                '${place.longitude}:${place.name.trim()}:${place.category?.trim()}',
          )
          .toList()
        ..sort();
  return [
    _selectionVersion,
    context.candidateIdentity,
    context.centerLatitude.toStringAsFixed(4),
    context.centerLongitude.toStringAsFixed(4),
    context.zoom.toStringAsFixed(1),
    context.width.toStringAsFixed(1),
    context.height.toStringAsFixed(1),
    context.metersPerPixel.toStringAsFixed(4),
    context.queryRadiusMeters.toStringAsFixed(1),
    config.markerFootprintPx,
    config.markerGapPx,
    config.viewportPaddingPx,
    config.minMarkers,
    config.maxMarkers,
    config.minDensityFactor,
    fingerprint.join('|'),
  ].join(':');
}
