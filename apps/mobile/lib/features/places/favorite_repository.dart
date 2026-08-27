import 'dart:io' show SocketException;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/config/supabase_config.dart';
import 'package:savorseek/features/auth/auth_service.dart';

import 'place_models.dart';

/// A user-scoped projection of a public place saved by the current user.
class FavoritePlace {
  const FavoritePlace({
    required this.favoriteId,
    required this.place,
    required this.createdAt,
  });

  final String favoriteId;
  final Place place;
  final DateTime createdAt;

  factory FavoritePlace.fromJson(Map<String, dynamic> json) {
    final favoriteId = json['favorite_id'];
    final placeId = json['place_id'];
    final name = json['name'];
    final fetchedAt = json['fetched_at'];
    final createdAt = json['created_at'];
    if (favoriteId is! String ||
        placeId is! String ||
        name is! String ||
        fetchedAt is! String ||
        createdAt is! String) {
      throw const FormatException(
        'favorite response is missing required fields',
      );
    }
    final fetched = DateTime.tryParse(fetchedAt);
    final created = DateTime.tryParse(createdAt);
    if (fetched == null || created == null) {
      throw const FormatException(
        'favorite response contains invalid timestamps',
      );
    }

    return FavoritePlace(
      favoriteId: favoriteId,
      createdAt: created.toLocal(),
      place: Place(
        id: placeId,
        name: name,
        category: json['category'] as String?,
        address: json['address'] as String?,
        latitude: _readDouble(json['latitude']),
        longitude: _readDouble(json['longitude']),
        fetchedAt: fetched.toLocal(),
      ),
    );
  }

  static double? _readDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

/// Stable failure categories for favorite reads and writes.
enum FavoriteErrorKind {
  invalidRequest,
  unauthenticated,
  placeNotFound,
  permissionDenied,
  idempotencyConflict,
  network,
  notConfigured,
  unavailable,
  storage,
}

class FavoriteRepositoryException implements Exception {
  const FavoriteRepositoryException(this.message, {required this.kind});

  final String message;
  final FavoriteErrorKind kind;

  bool get isRetryable => switch (kind) {
    FavoriteErrorKind.network || FavoriteErrorKind.unavailable => true,
    _ => false,
  };

  @override
  String toString() => message;
}

abstract interface class FavoriteRepository {
  Future<Set<String>> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  });

  Future<void> addFavorite({
    required String placeId,
    required String idempotencyKey,
  });

  Future<void> removeFavorite({
    required String placeId,
    required String idempotencyKey,
  });

  Future<List<FavoritePlace>> listFavorites({int limit = 20, int offset = 0});
}

/// Explicit unavailable implementation used when bootstrap could not connect.
class UnavailableFavoriteRepository implements FavoriteRepository {
  const UnavailableFavoriteRepository([this.reason]);

  final String? reason;

  @override
  Future<Set<String>> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  }) => _fail();

  @override
  Future<void> addFavorite({
    required String placeId,
    required String idempotencyKey,
  }) => _fail();

  @override
  Future<void> removeFavorite({
    required String placeId,
    required String idempotencyKey,
  }) => _fail();

  @override
  Future<List<FavoritePlace>> listFavorites({int limit = 20, int offset = 0}) =>
      _fail();

  Future<Never> _fail() async {
    throw FavoriteRepositoryException(
      reason ?? '收藏服务尚未就绪。',
      kind: FavoriteErrorKind.notConfigured,
    );
  }
}

/// Narrow transport seam around Supabase RPC calls.
abstract interface class FavoriteRpcPort {
  Future<Object?> invoke(String name, Map<String, dynamic> params);
}

class SupabaseFavoriteRpcPort implements FavoriteRpcPort {
  SupabaseFavoriteRpcPort(SupabaseClient client) : _client = client;

  final SupabaseClient _client;

  @override
  Future<Object?> invoke(String name, Map<String, dynamic> params) {
    return _client.rpc<dynamic>(name, params: params);
  }
}

class SupabaseFavoriteRepository implements FavoriteRepository {
  SupabaseFavoriteRepository({
    required this.auth,
    FavoriteRpcPort? rpcPort,
    SupabaseClient? client,
  }) : _rpcPort =
           rpcPort ??
           SupabaseFavoriteRpcPort(client ?? Supabase.instance.client);

  final AuthService auth;
  final FavoriteRpcPort _rpcPort;

  @override
  Future<Set<String>> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  }) async {
    _requireSession();
    final ids = placeIds.toSet().toList(growable: false);
    if (ids.length > 100) {
      throw const FavoriteRepositoryException(
        '一次最多检查 100 个地点的收藏状态。',
        kind: FavoriteErrorKind.invalidRequest,
      );
    }
    final response = await _invoke('get_favorite_statuses', {
      'p_place_ids': ids,
    });
    return _parseIds(response);
  }

  @override
  Future<void> addFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {
    _requireSession();
    final response = await _invoke('add_favorite', {
      'p_place_id': placeId,
      'p_idempotency_key': idempotencyKey,
    });
    _validateMutationResponse(response, placeId, expectedFavorite: true);
  }

  @override
  Future<void> removeFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {
    _requireSession();
    final response = await _invoke('remove_favorite', {
      'p_place_id': placeId,
      'p_idempotency_key': idempotencyKey,
    });
    _validateMutationResponse(response, placeId, expectedFavorite: false);
  }

  @override
  Future<List<FavoritePlace>> listFavorites({
    int limit = 20,
    int offset = 0,
  }) async {
    _requireSession();
    if (limit < 1 || limit > 100 || offset < 0) {
      throw const FavoriteRepositoryException(
        '收藏列表分页参数无效。',
        kind: FavoriteErrorKind.invalidRequest,
      );
    }
    final response = await _invoke('list_favorites', {
      'p_limit': limit,
      'p_offset': offset,
    });
    if (response is! Map) _malformed();
    final rows = response['items'];
    if (rows is! List) _malformed();
    try {
      return rows
          .whereType<Map>()
          .map((row) => FavoritePlace.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false);
    } on FormatException {
      _malformed();
    } on TypeError {
      _malformed();
    }
  }

  void _requireSession() {
    if (!SupabaseConfig.isConfigured) {
      throw const FavoriteRepositoryException(
        '收藏服务尚未配置。',
        kind: FavoriteErrorKind.notConfigured,
      );
    }
    if (!auth.isSignedIn) {
      throw const FavoriteRepositoryException(
        '登录后即可收藏地点。',
        kind: FavoriteErrorKind.unauthenticated,
      );
    }
  }

  Future<Object?> _invoke(String name, Map<String, dynamic> params) async {
    try {
      return await _rpcPort.invoke(name, params);
    } on PostgrestException catch (error) {
      throw translateFavoritePostgrestError(
        code: error.code,
        message: error.message,
      );
    } on SocketException catch (_) {
      throw const FavoriteRepositoryException(
        '无法保存收藏，请检查网络后重试。',
        kind: FavoriteErrorKind.network,
      );
    }
  }

  Set<String> _parseIds(Object? response) {
    if (response is! List) _malformed();
    final ids = <String>{};
    for (final value in response) {
      if (value is! String || value.isEmpty) _malformed();
      ids.add(value);
    }
    return Set.unmodifiable(ids);
  }

  void _validateMutationResponse(
    Object? response,
    String placeId, {
    required bool expectedFavorite,
  }) {
    if (response is! Map ||
        response['place_id'] != placeId ||
        response['is_favorite'] != expectedFavorite) {
      _malformed();
    }
  }

  Never _malformed() {
    throw const FavoriteRepositoryException(
      '收藏服务返回了非预期的结果。',
      kind: FavoriteErrorKind.storage,
    );
  }
}

/// Small deterministic fake useful for local demos and widget tests.
class InMemoryFavoriteRepository implements FavoriteRepository {
  InMemoryFavoriteRepository({Iterable<FavoritePlace> favorites = const []})
    : _favorites = {
        for (final favorite in favorites) favorite.place.id: favorite,
      },
      _favoriteIds = favorites.map((favorite) => favorite.place.id).toSet();

  final Map<String, FavoritePlace> _favorites;
  final Set<String> _favoriteIds;

  @override
  Future<Set<String>> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  }) async {
    final requested = placeIds.toSet();
    if (requested.isEmpty) return Set.unmodifiable(_favoriteIds);
    return Set.unmodifiable(_favoriteIds.where(requested.contains).toSet());
  }

  @override
  Future<void> addFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {
    _favoriteIds.add(placeId);
  }

  @override
  Future<void> removeFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {
    _favoriteIds.remove(placeId);
    _favorites.remove(placeId);
  }

  @override
  Future<List<FavoritePlace>> listFavorites({
    int limit = 20,
    int offset = 0,
  }) async {
    final values = _favorites.values.toList(growable: false);
    return values.skip(offset).take(limit).toList(growable: false);
  }
}

FavoriteRepositoryException translateFavoritePostgrestError({
  required String? code,
  required String message,
}) {
  return switch (code) {
    '28000' || 'PGRST301' => const FavoriteRepositoryException(
      '登录状态已失效，请重新登录。',
      kind: FavoriteErrorKind.unauthenticated,
    ),
    '22023' when message.contains('place not found') =>
      const FavoriteRepositoryException(
        '这个地点已无法收藏，可能已被下架。',
        kind: FavoriteErrorKind.placeNotFound,
      ),
    '22023' when message.contains('idempotency') =>
      const FavoriteRepositoryException(
        '收藏请求已失效，请重新操作。',
        kind: FavoriteErrorKind.idempotencyConflict,
      ),
    '42501' => const FavoriteRepositoryException(
      '当前账号无法修改这条收藏。',
      kind: FavoriteErrorKind.permissionDenied,
    ),
    '40001' || 'PGRST003' => const FavoriteRepositoryException(
      '收藏服务暂时不可用，请稍后重试。',
      kind: FavoriteErrorKind.unavailable,
    ),
    _ => FavoriteRepositoryException(
      '收藏服务暂时不可用，请稍后重试。',
      kind: FavoriteErrorKind.storage,
    ),
  };
}
