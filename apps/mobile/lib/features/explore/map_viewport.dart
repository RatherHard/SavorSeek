import 'dart:math' as math;

/// A camera center used by the viewport query calculator.
class MapViewportCenter {
  const MapViewportCenter({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
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
    required this.key,
  });

  final MapViewportCenter center;
  final double zoom;
  final int radiusMeters;
  final double metersPerPixel;
  final double width;
  final double height;
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
    key: key,
  );
}

bool _isFinite(double value) => value.isFinite;

double _round(double value, int decimals) {
  final factor = math.pow(10, decimals).toDouble();
  return (value * factor).round() / factor;
}

int _roundTo(int value, int step) => ((value + step ~/ 2) ~/ step) * step;
