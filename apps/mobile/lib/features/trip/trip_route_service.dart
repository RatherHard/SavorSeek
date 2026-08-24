import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/config/supabase_config.dart';
import 'package:savorseek/features/auth/auth_service.dart';

/// 路线上的一个点。
///
/// 不直接复用 `LatLng`：那是高德插件的类型，让服务层依赖它会把地图 SDK 拖进
/// 无需渲染的单元测试。坐标系恒为 gcj02（与高德底图及 place_snapshot 一致）。
@immutable
class RoutePoint {
  const RoutePoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

/// 真实路网路线的来源。
///
/// 抽成接口而非直接调 Edge Function：Widget 测试无法初始化 Supabase，只有
/// 依赖可替换才能覆盖「取到路线」「服务不可用退化直线」两条分支。
abstract interface class TripRouteService {
  /// 依次连接 [points]，返回沿真实路网的路径点。
  ///
  /// 少于两个点时返回空列表。抛 [TripRouteException] 表示不可用，调用方应退化为
  /// 直线连接而不是让地图失效。
  Future<List<RoutePoint>> resolveRoute({required List<RoutePoint> points});
}

/// 经 Supabase Edge Function 取高德步行/驾车路线。
///
/// 为什么不在客户端直接调高德 Web 服务 API：Web 服务 Key 一旦打进 APK 就可被
/// 反编译提取，配额不可控。这与地点检索的既有约定一致（见 place_repository.dart）。
class EdgeFunctionRouteService implements TripRouteService {
  EdgeFunctionRouteService({required this.auth, SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  static const String _functionName = 'trip-route';

  final AuthService auth;
  final SupabaseClient _client;

  @override
  Future<List<RoutePoint>> resolveRoute({
    required List<RoutePoint> points,
  }) async {
    if (points.length < 2) return const [];
    if (!SupabaseConfig.isConfigured) {
      throw const TripRouteException('未配置路线服务');
    }
    if (!auth.isSignedIn) {
      throw const TripRouteException('未登录');
    }

    try {
      final response = await _client.functions.invoke(
        _functionName,
        body: {
          'points': [
            for (final point in points)
              {'latitude': point.latitude, 'longitude': point.longitude},
          ],
        },
      );
      return _parse(response.data);
    } on FunctionException catch (error) {
      throw TripRouteException(reasonFrom(error.details));
    } on SocketException catch (_) {
      throw const TripRouteException('网络不可用');
    }
  }

  List<RoutePoint> _parse(Object? data) {
    if (data is! Map) throw const TripRouteException('返回内容异常');
    final path = data['path'];
    if (path is! List) throw const TripRouteException('返回内容异常');
    return [
      for (final point in path)
        if (point is Map)
          if (toDouble(point['latitude']) case final latitude?)
            if (toDouble(point['longitude']) case final longitude?)
              RoutePoint(latitude: latitude, longitude: longitude),
    ];
  }

  /// jsonb 的数字可能是 int、double 或字符串，故统一归一化。
  static double? toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// 把函数返回的错误体归纳成一句可展示的原因。
  ///
  /// 只做粗分类：用户看到的是地图角上的一行小字，展开完整错误码没有意义。
  /// 错误体形状与 places-search 一致：`{"error":{"code":...,"message":...}}`。
  static String reasonFrom(Object? details) {
    final payload = details is Map ? details['error'] : null;
    final code = payload is Map ? payload['code'] : null;
    return switch (code) {
      'unauthenticated' => '登录状态已失效',
      'provider_key_missing' || 'provider_key_rejected' => '服务未配置',
      'provider_quota_exceeded' => '请求过于频繁',
      'invalid_request' => '路线请求无效',
      _ => '路线服务暂不可用',
    };
  }
}

class TripRouteException implements Exception {
  const TripRouteException(this.message);

  final String message;

  @override
  String toString() => message;
}
