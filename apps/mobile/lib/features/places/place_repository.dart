import 'dart:io' show SocketException;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/config/supabase_config.dart';
import 'package:savorseek/features/auth/auth_service.dart';

import 'place_models.dart';

/// 地点检索的失败原因。
///
/// 与 `supabase/functions/places-search/errors.ts` 的 `code` 一一对应，外加两个
/// 只可能在客户端出现的成因（未配置连接参数、网络不可达）。
///
/// 刻意按 code 而非 message 分支：message 是面向用户的文案，随时可改；code 才是
/// 两端的契约。设计文档 §12 要求空结果与各类失败必须给出不同提示，靠文案匹配
/// 会在后端改一个字时静默失效。
enum PlaceSearchFailure {
  /// 请求参数非法，含「地图视野无效」这一子情形。
  invalidRequest,
  unauthenticated,

  /// 服务端未配置高德 Web 服务 Key。属部署问题，用户无法自行解决。
  providerKeyMissing,

  /// Key 存在但被高德拒绝（无效、过期、白名单不匹配）。
  providerKeyRejected,
  providerQuotaExceeded,

  /// 上游检索服务不可用或超时。
  providerUnavailable,
  storageFailure,

  /// 客户端未注入 Supabase 连接参数。
  notConfigured,

  /// 客户端网络不可达。
  network,
}

class PlaceSearchException implements Exception {
  const PlaceSearchException(this.message, {required this.failure});

  final String message;
  final PlaceSearchFailure failure;

  @override
  String toString() => message;
}

abstract interface class PlaceRepository {
  /// 按关键词检索。[city] 为空时不限定城市。
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  });

  /// 按坐标检索周边。
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters,
    String? keywords,
  });
}

/// 后端不可用时的占位实现，让「未注入参数」与「检索失败」走同一条 UI 分支。
class UnavailablePlaceRepository implements PlaceRepository {
  const UnavailablePlaceRepository([this.message]);

  final String? message;

  @override
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  }) => _fail();

  @override
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters = 3000,
    String? keywords,
  }) => _fail();

  Future<PlaceSearchResult> _fail() async {
    throw PlaceSearchException(
      message ?? SupabaseConfig.missingMessage,
      failure: PlaceSearchFailure.notConfigured,
    );
  }
}

/// 经 `places-search` Edge Function 检索地点。
///
/// 为什么不直接查 `places` 表：表里只有已缓存的地点，且高德 Web 服务 Key 必须
/// 留在服务端（`amap_map` 插件不含 POI 搜索能力，检索只能走 Web 服务 API）。
/// 函数因此同时承担鉴权、配额控制与结果落库。
class SupabasePlaceRepository implements PlaceRepository {
  SupabasePlaceRepository({required this.auth, SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  static const String _functionName = 'places-search';

  final AuthService auth;
  final SupabaseClient _client;

  @override
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  }) {
    final trimmed = keywords.trim();
    if (trimmed.isEmpty) {
      throw const PlaceSearchException(
        '请输入要查找的关键词。',
        failure: PlaceSearchFailure.invalidRequest,
      );
    }
    return _invoke({
      'kind': 'text',
      'keywords': trimmed,
      if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
    });
  }

  @override
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters = 3000,
    String? keywords,
  }) {
    return _invoke({
      'kind': 'around',
      'latitude': latitude,
      'longitude': longitude,
      'radius': radiusMeters,
      if (keywords != null && keywords.trim().isNotEmpty)
        'keywords': keywords.trim(),
    });
  }

  Future<PlaceSearchResult> _invoke(Map<String, dynamic> body) async {
    _requireSession();
    try {
      final response = await _client.functions.invoke(
        _functionName,
        body: body,
      );
      return _parse(response.data);
    } on FunctionException catch (error) {
      throw _translateFunctionError(error);
    } on SocketException catch (_) {
      throw const PlaceSearchException(
        '无法连接地点检索服务，请检查网络后重试。',
        failure: PlaceSearchFailure.network,
      );
    }
  }

  void _requireSession() {
    if (!SupabaseConfig.isConfigured) {
      throw PlaceSearchException(
        SupabaseConfig.missingMessage,
        failure: PlaceSearchFailure.notConfigured,
      );
    }
    // 函数侧也会校验，此处提前拦截是为了省一次往返并给出一致的文案。
    if (!auth.isSignedIn) {
      throw const PlaceSearchException(
        '登录后即可检索美食地点。',
        failure: PlaceSearchFailure.unauthenticated,
      );
    }
  }

  PlaceSearchResult _parse(Object? data) {
    if (data is! Map) {
      throw const PlaceSearchException(
        '地点检索返回了非预期的结果。',
        failure: PlaceSearchFailure.storageFailure,
      );
    }
    final rows = data['places'];
    final places = rows is List
        ? rows
              .whereType<Map>()
              .map((row) => Place.fromJson(Map<String, dynamic>.from(row)))
              .toList(growable: false)
        : const <Place>[];
    final fetchedAt = data['fetched_at'];
    return PlaceSearchResult(
      places: places,
      fromCache: data['from_cache'] == true,
      fetchedAt: fetchedAt is String
          ? DateTime.tryParse(fetchedAt)?.toLocal()
          : null,
    );
  }
}

/// 把函数返回的错误体翻译成客户端分支。
///
/// `FunctionException.details` 在非 2xx 时携带响应体。函数总是返回
/// `{"error":{"code":...,"message":...}}`，因此优先取其中的 code；缺失时按 HTTP
/// 状态兜底，不猜测具体成因。
PlaceSearchException translateFunctionError({
  required int status,
  required Object? details,
}) {
  final payload = details is Map ? details['error'] : null;
  final code = payload is Map ? payload['code'] : null;
  final message = payload is Map ? payload['message'] as String? : null;

  final failure = switch (code) {
    'invalid_request' => PlaceSearchFailure.invalidRequest,
    'unauthenticated' => PlaceSearchFailure.unauthenticated,
    'provider_key_missing' => PlaceSearchFailure.providerKeyMissing,
    'provider_key_rejected' => PlaceSearchFailure.providerKeyRejected,
    'provider_quota_exceeded' => PlaceSearchFailure.providerQuotaExceeded,
    'provider_unavailable' => PlaceSearchFailure.providerUnavailable,
    'storage_failure' => PlaceSearchFailure.storageFailure,
    // 未知 code 或响应体不合预期：按状态码归类，401 之外一律视为服务端问题。
    _ =>
      status == 401
          ? PlaceSearchFailure.unauthenticated
          : PlaceSearchFailure.storageFailure,
  };

  return PlaceSearchException(
    message ?? _fallbackMessage(failure),
    failure: failure,
  );
}

String _fallbackMessage(PlaceSearchFailure failure) {
  return switch (failure) {
    PlaceSearchFailure.unauthenticated => '登录状态已失效，请重新登录。',
    PlaceSearchFailure.invalidRequest => '检索条件不合法，请调整后重试。',
    _ => '地点检索暂时不可用，请稍后重试。',
  };
}

PlaceSearchException _translateFunctionError(FunctionException error) =>
    translateFunctionError(status: error.status, details: error.details);
