import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:x_amap_base/x_amap_base.dart';

/// A validated, one-shot device position in the coordinate system expected by AMap.
@immutable
class DeviceLocation {
  const DeviceLocation({required this.latitude, required this.longitude});

  factory DeviceLocation.validated({
    required double latitude,
    required double longitude,
  }) {
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      throw const LocationException(
        '当前位置无效。',
        failure: LocationFailure.invalid,
      );
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      throw const LocationException(
        '当前位置无效。',
        failure: LocationFailure.invalid,
      );
    }
    return DeviceLocation(latitude: latitude, longitude: longitude);
  }

  final double latitude;
  final double longitude;

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
  };
}

enum LocationFailure {
  permissionDenied,
  permissionPermanentlyDenied,
  serviceDisabled,
  timeout,
  unavailable,
  invalid,
}

class LocationException implements Exception {
  const LocationException(this.message, {required this.failure});

  final String message;
  final LocationFailure failure;

  @override
  String toString() => message;
}

/// Supplies a single foreground location for nearby recommendations.
abstract interface class LocationService {
  Future<DeviceLocation> getCurrentLocation();
}

class AmapLocationService implements LocationService {
  AmapLocationService({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;
  Completer<DeviceLocation> _location = Completer<DeviceLocation>();

  void update(AMapLocation location) {
    if (_location.isCompleted) return;
    try {
      _location.complete(
        DeviceLocation.validated(
          latitude: location.latLng.latitude,
          longitude: location.latLng.longitude,
        ),
      );
    } on LocationException catch (error) {
      _location.completeError(error);
      _location = Completer<DeviceLocation>();
    }
  }

  @override
  Future<DeviceLocation> getCurrentLocation() async {
    try {
      return await _location.future.timeout(timeout);
    } on TimeoutException {
      _location = Completer<DeviceLocation>();
      throw const LocationException(
        '获取当前位置超时，请重试。',
        failure: LocationFailure.timeout,
      );
    }
  }
}

/// Offline/configuration fallback that never invents a location.
class UnavailableLocationService implements LocationService {
  const UnavailableLocationService([this.reason]);

  final String? reason;

  @override
  Future<DeviceLocation> getCurrentLocation() async {
    throw LocationException(
      reason ?? '暂时无法获取当前位置。',
      failure: LocationFailure.unavailable,
    );
  }
}
