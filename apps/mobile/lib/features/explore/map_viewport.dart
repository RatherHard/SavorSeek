import 'dart:math' as math;

/// A camera center used by the viewport query calculator.
class MapViewportCenter {
  const MapViewportCenter({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

/// A Web Mercator viewport boundary. `west > east` means the boundary crosses
/// the antimeridian.
class MapViewportBounds {
  const MapViewportBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;

  bool get crossesAntimeridian => west > east;

  bool containsLongitude(double longitude) => crossesAntimeridian
      ? longitude >= west || longitude <= east
      : longitude >= west && longitude <= east;

  bool contains({required double latitude, required double longitude}) =>
      latitude >= south && latitude <= north && containsLongitude(longitude);
}

/// A normalized, cache-friendly query for places around the visible map area.
class MapViewportQuery {
  const MapViewportQuery({
    required this.center,
    required this.zoom,
    required this.radiusMeters,
    required this.metersPerPixel,
    required this.width,
    required this.height,
    required this.bounds,
    required this.key,
  });

  final MapViewportCenter center;
  final double zoom;
  final int radiusMeters;
  final double metersPerPixel;
  final double width;
  final double height;
  final MapViewportBounds bounds;
  final String key;
}

/// Calculates a conservative radius around a map camera center.
///
/// The map plugin does not expose a stable visible-region API. This deliberately
/// estimates a circle large enough to cover the viewport instead of pretending
/// to calculate an exact rectangle.
MapViewportQuery? buildMapViewportQuery({
  required double latitude,
  required double longitude,
  required double zoom,
  required double width,
  required double height,
}) {
  if (!_isFinite(latitude) || !_isFinite(longitude) || !_isFinite(zoom)) {
    return null;
  }
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    return null;
  }
  if (zoom < 0 || zoom > 24 || width <= 0 || height <= 0) return null;
  if (!_isFinite(width) || !_isFinite(height)) return null;

  final clampedLatitude = latitude.clamp(-85.0, 85.0).toDouble();
  final metersPerPixel =
      156543.03392 *
      math.cos(clampedLatitude * math.pi / 180) /
      math.pow(2, zoom);
  final cornerPixels = math.sqrt(width * width + height * height) / 2;
  final estimatedRadius = (cornerPixels * metersPerPixel * 1.25).round();
  final radiusMeters = estimatedRadius.clamp(1, 50000);

  final normalizedLatitude = _round(latitude, 4);
  final normalizedLongitude = _round(longitude, 4);
  final normalizedZoom = _round(zoom, 1);
  final normalizedRadius = math.max(1, _roundTo(radiusMeters, 100));
  final normalizedWidth = _round(width, 1);
  final normalizedHeight = _round(height, 1);
  final bounds = _buildApproximateBounds(
    latitude: latitude,
    longitude: longitude,
    zoom: zoom,
    width: width,
    height: height,
  );
  if (bounds == null) return null;
  final key =
      '$normalizedLatitude:$normalizedLongitude:'
      '$normalizedZoom:$normalizedRadius:$normalizedWidth:$normalizedHeight';

  return MapViewportQuery(
    center: MapViewportCenter(
      latitude: normalizedLatitude,
      longitude: normalizedLongitude,
    ),
    zoom: normalizedZoom,
    radiusMeters: normalizedRadius,
    metersPerPixel: metersPerPixel,
    width: width,
    height: height,
    bounds: bounds,
    key: key,
  );
}

MapViewportBounds? _buildApproximateBounds({
  required double latitude,
  required double longitude,
  required double zoom,
  required double width,
  required double height,
}) {
  final worldSize = 256 * math.pow(2, zoom).toDouble();
  final centerX = (longitude + 180) / 360 * worldSize;
  final sine = math.sin(latitude * math.pi / 180).clamp(-0.9999, 0.9999);
  final centerY =
      (0.5 - math.log((1 + sine) / (1 - sine)) / (4 * math.pi)) * worldSize;
  final west = _worldXToLongitude(centerX - width / 2, worldSize);
  final east = _worldXToLongitude(centerX + width / 2, worldSize);
  final south = _worldYToLatitude(centerY + height / 2, worldSize);
  final north = _worldYToLatitude(centerY - height / 2, worldSize);
  if (![west, east, south, north].every(_isFinite)) return null;
  return MapViewportBounds(
    south: south.clamp(-85.0511, 85.0511).toDouble(),
    west: west,
    north: north.clamp(-85.0511, 85.0511).toDouble(),
    east: east,
  );
}

bool _isFinite(double value) => value.isFinite;

double _worldXToLongitude(double x, double worldSize) {
  final wrapped = ((x % worldSize) + worldSize) % worldSize;
  return wrapped / worldSize * 360 - 180;
}

double _worldYToLatitude(double y, double worldSize) {
  final normalized = (y / worldSize).clamp(0.0, 1.0);
  final value = math.pi * (1 - 2 * normalized);
  final sinh = (math.exp(value) - math.exp(-value)) / 2;
  return 180 / math.pi * math.atan(sinh);
}

double _round(double value, int decimals) {
  final factor = math.pow(10, decimals).toDouble();
  return (value * factor).round() / factor;
}

int _roundTo(int value, int step) => ((value + step ~/ 2) ~/ step) * step;
