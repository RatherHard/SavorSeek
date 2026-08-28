import 'dart:math' as math;

import 'package:savorseek/features/places/place_models.dart';

const _selectionVersion = 'marker-selection-v1';
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
  final cellSize = config.markerFootprintPx + config.markerGapPx;
  final selected = <Place>[];
  final occupied = <String, Place>{};

  for (final place in visible) {
    if (selected.length >= target) break;
    final point = _project(place, context);
    final cell =
        '${(point.$1 / cellSize).floor()}:${(point.$2 / cellSize).floor()}';
    if (occupied.containsKey(cell) ||
        _tooClose(point, selected, context, config)) {
      continue;
    }
    occupied[cell] = place;
    selected.add(place);
  }

  return MapMarkerSelectionResult(
    places: List.unmodifiable(selected),
    targetCount: target,
    eligibleCount: normalized.length,
    selectionKey: key,
    isValid: true,
  );
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
    place.longitude! <= 180 &&
    isValidAmapRating(place.rating);

int _compare(Place a, Place b, MapMarkerSelectionContext context) {
  final rating = b.rating!.compareTo(a.rating!);
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
  return a.name.trim().compareTo(b.name.trim());
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
  MapMarkerSelectionConfig config,
) {
  final spacing = config.markerFootprintPx + config.markerGapPx;
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
  return math.min(
    eligibleCount,
    math.min(config.maxMarkers, math.max(config.minMarkers, capacity)),
  );
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
