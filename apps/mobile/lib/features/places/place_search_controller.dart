import 'package:flutter/foundation.dart';

import 'place_models.dart';
import 'place_repository.dart';
import 'place_search_query.dart';

/// 查询结果的来源。
enum PlaceSearchSource { keyword, viewport }

/// 探索页的检索状态。
sealed class PlaceSearchState {
  const PlaceSearchState();
}

/// 尚未检索过。地图只显示底图。
final class PlaceSearchIdle extends PlaceSearchState {
  const PlaceSearchIdle();
}

final class PlaceSearchLoading extends PlaceSearchState {
  const PlaceSearchLoading(
    this.keywords, {
    this.source = PlaceSearchSource.keyword,
  });

  final String keywords;
  final PlaceSearchSource source;
}

final class PlaceSearchLoaded extends PlaceSearchState {
  const PlaceSearchLoaded({
    required this.keywords,
    required this.result,
    this.source = PlaceSearchSource.keyword,
    this.queryKey,
  });

  final String keywords;
  final PlaceSearchResult result;
  final PlaceSearchSource source;
  final String? queryKey;

  List<Place> get places => result.places;
}

/// 检索成功但无结果。
///
/// 与 [PlaceSearchFailed] 分开是刻意的：设计文档 §12 要求「没有符合条件的地点」
/// 与「数据源不可用」给出不同提示，合成一个状态就无法区分。
final class PlaceSearchEmpty extends PlaceSearchState {
  const PlaceSearchEmpty(
    this.keywords, {
    this.source = PlaceSearchSource.keyword,
  });

  final String keywords;
  final PlaceSearchSource source;
}

final class PlaceSearchFailed extends PlaceSearchState {
  const PlaceSearchFailed({
    required this.keywords,
    required this.message,
    required this.failure,
    this.source = PlaceSearchSource.keyword,
    this.queryKey,
    this.hasPreviousResult = false,
  });

  final String keywords;
  final String message;
  final PlaceSearchFailure failure;
  final PlaceSearchSource source;
  final String? queryKey;
  final bool hasPreviousResult;

  /// 是否值得让用户重试。
  ///
  /// Key 缺失或被拒属服务端配置问题，重试永远不会成功，给出重试按钮只会让用户
  /// 反复徒劳；配额与网络类则可能几秒后恢复。
  bool get isRetryable => switch (failure) {
    PlaceSearchFailure.providerKeyMissing ||
    PlaceSearchFailure.providerKeyRejected ||
    PlaceSearchFailure.notConfigured ||
    PlaceSearchFailure.invalidRequest => false,
    _ => true,
  };
}

/// 驱动探索页的地点检索。
///
/// 只负责「发起检索、暴露状态、记录选中项」，不碰地图 SDK：标记的构造在 UI 层
/// 完成，领域层不引入 `amap_map` 的类型。
class PlaceSearchController extends ChangeNotifier {
  PlaceSearchController(this._repository);

  final PlaceRepository _repository;

  PlaceSearchState _state = const PlaceSearchIdle();
  Place? _selected;
  bool _isDisposed = false;

  /// 用于丢弃过期响应的序号。
  ///
  /// 连续两次检索时，先发的请求可能后到，若不加判别会用旧结果覆盖新结果。
  int _requestId = 0;
  String? _lastViewportKey;
  PlaceSearchResult? _viewportResult;
  PlaceSearchResult? _keywordResult;
  String? _lastViewportKeywords;
  double? _lastViewportLatitude;
  double? _lastViewportLongitude;
  int? _lastViewportRadius;
  PlaceSearchQuery? _lastViewportQuery;

  /// 当前应显示的结果。手动关键词结果优先，视野刷新不会静默替换它。
  List<Place> get visiblePlaces {
    final state = _state;
    if (state case PlaceSearchLoaded(:final places)
        when state.source == PlaceSearchSource.keyword) {
      return places;
    }
    final keywordResult = _keywordResult;
    if (keywordResult != null) return keywordResult.places;
    if (state case PlaceSearchLoaded(:final places)) return places;
    return _viewportResult?.places ?? const <Place>[];
  }

  /// 当前地图应使用的候选。视野检索成功后优先使用最新视野批次，避免关键词结果
  /// 在地图移动后继续作为过期 marker 来源；尚未有视野结果时回退到可见结果。
  List<Place> get mapPlaces => _viewportResult?.places ?? visiblePlaces;

  PlaceSearchState get state => _state;

  /// 当前选中的地点，决定详情面板是否展开。
  Place? get selected => _selected;

  bool get isLoading => _state is PlaceSearchLoading;

  bool get isKeywordMode => switch (_state) {
    PlaceSearchLoading(:final source) ||
    PlaceSearchLoaded(:final source) ||
    PlaceSearchEmpty(:final source) ||
    PlaceSearchFailed(:final source) => source == PlaceSearchSource.keyword,
    PlaceSearchIdle() => false,
  };

  bool get hasViewportResult => _viewportResult != null;

  Future<void> searchAround({
    required double latitude,
    required double longitude,
    required int radiusMeters,
    String? queryKey,
    String? keywords,
  }) async {
    if (queryKey != null && queryKey == _lastViewportKey) return;

    final requestId = ++_requestId;
    final previous = _viewportResult;
    final trimmed = keywords?.trim() ?? '';
    _lastViewportKey = queryKey;
    _lastViewportKeywords = trimmed;
    _lastViewportLatitude = latitude;
    _lastViewportLongitude = longitude;
    _lastViewportRadius = radiusMeters;
    _setState(PlaceSearchLoading(trimmed, source: PlaceSearchSource.viewport));

    try {
      final result = await _repository.searchAround(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
        keywords: trimmed.isEmpty ? null : trimmed,
      );
      if (_isStale(requestId)) return;
      _viewportResult = result;
      _lastViewportKey = queryKey;
      _lastViewportKeywords = trimmed;
      _lastViewportLatitude = latitude;
      _lastViewportLongitude = longitude;
      _lastViewportRadius = radiusMeters;
      _setState(
        result.isEmpty
            ? PlaceSearchEmpty(trimmed, source: PlaceSearchSource.viewport)
            : PlaceSearchLoaded(
                keywords: trimmed,
                result: result,
                source: PlaceSearchSource.viewport,
                queryKey: queryKey,
              ),
      );
    } on PlaceSearchException catch (error) {
      if (_isStale(requestId)) return;
      if (previous != null && !previous.isEmpty) {
        _setState(
          PlaceSearchFailed(
            keywords: trimmed,
            message: error.message,
            failure: error.failure,
            source: PlaceSearchSource.viewport,
            queryKey: queryKey,
            hasPreviousResult: true,
          ),
        );
        return;
      }
      _setState(
        PlaceSearchFailed(
          keywords: trimmed,
          message: error.message,
          failure: error.failure,
          source: PlaceSearchSource.viewport,
          queryKey: queryKey,
        ),
      );
    } on Exception {
      if (_isStale(requestId)) return;
      _setState(
        PlaceSearchFailed(
          keywords: trimmed,
          message: '地点检索暂时不可用，请稍后重试。',
          failure: PlaceSearchFailure.storageFailure,
          source: PlaceSearchSource.viewport,
          queryKey: queryKey,
          hasPreviousResult: previous != null && !previous.isEmpty,
        ),
      );
    }
  }

  Future<void> searchStructured({
    required PlaceSearchQuery query,
    String? queryKey,
  }) async {
    if (queryKey != null && queryKey == _lastViewportKey) return;
    final requestId = ++_requestId;
    final previous = _viewportResult;
    _lastViewportKey = queryKey;
    _lastViewportQuery = query;
    _setState(
      PlaceSearchLoading(
        query.keywords?.trim() ?? '',
        source: PlaceSearchSource.viewport,
      ),
    );
    try {
      final result = await _repository.search(query);
      if (_isStale(requestId)) return;
      _viewportResult = result;
      _setState(
        result.isEmpty
            ? PlaceSearchEmpty(
                query.keywords?.trim() ?? '',
                source: PlaceSearchSource.viewport,
              )
            : PlaceSearchLoaded(
                keywords: query.keywords?.trim() ?? '',
                result: result,
                source: PlaceSearchSource.viewport,
                queryKey: queryKey,
              ),
      );
    } on PlaceSearchException catch (error) {
      if (_isStale(requestId)) return;
      _setState(
        PlaceSearchFailed(
          keywords: query.keywords?.trim() ?? '',
          message: error.message,
          failure: error.failure,
          source: PlaceSearchSource.viewport,
          queryKey: queryKey,
          hasPreviousResult: previous != null && !previous.isEmpty,
        ),
      );
    } on Exception {
      if (_isStale(requestId)) return;
      _setState(
        PlaceSearchFailed(
          keywords: query.keywords?.trim() ?? '',
          message: '地点检索暂时不可用，请稍后重试。',
          failure: PlaceSearchFailure.storageFailure,
          source: PlaceSearchSource.viewport,
          queryKey: queryKey,
          hasPreviousResult: previous != null && !previous.isEmpty,
        ),
      );
    }
  }

  List<Place>? get viewportPlaces => _viewportResult?.places;

  Future<void> searchByKeywords(String keywords, {String? city}) async {
    final trimmed = keywords.trim();
    if (trimmed.isEmpty) return;

    final requestId = ++_requestId;
    // 新检索作废旧的选中项：详情面板里的地点可能已不在新结果中。
    _selected = null;
    _keywordResult = null;
    _viewportResult = null;
    _lastViewportKey = null;
    _lastViewportQuery = null;
    _setState(PlaceSearchLoading(trimmed));

    try {
      final result = await _repository.searchByKeywords(
        keywords: trimmed,
        city: city,
      );
      if (_isStale(requestId)) return;
      _keywordResult = result;
      _setState(
        result.isEmpty
            ? PlaceSearchEmpty(trimmed)
            : PlaceSearchLoaded(keywords: trimmed, result: result),
      );
    } on PlaceSearchException catch (error) {
      if (_isStale(requestId)) return;
      _setState(
        PlaceSearchFailed(
          keywords: trimmed,
          message: error.message,
          failure: error.failure,
        ),
      );
    } on Exception {
      if (_isStale(requestId)) return;
      _setState(
        PlaceSearchFailed(
          keywords: trimmed,
          message: '地点检索暂时不可用，请稍后重试。',
          failure: PlaceSearchFailure.storageFailure,
        ),
      );
    }
  }

  /// 重试上一次检索。仅在失败或空结果状态下有意义。
  Future<void> retry({String? city}) async {
    final source = switch (_state) {
      PlaceSearchFailed(:final source) => source,
      PlaceSearchEmpty(:final source) => source,
      _ => null,
    };
    if (source == PlaceSearchSource.viewport) {
      final query = _lastViewportQuery;
      if (query != null) {
        await searchStructured(query: query, queryKey: _lastViewportKey);
        return;
      }
      final latitude = _lastViewportLatitude;
      final longitude = _lastViewportLongitude;
      final radius = _lastViewportRadius;
      if (latitude != null && longitude != null && radius != null) {
        await searchAround(
          latitude: latitude,
          longitude: longitude,
          radiusMeters: radius,
          queryKey: _lastViewportKey,
          keywords: _lastViewportKeywords,
        );
      }
      return;
    }

    final keywords = switch (_state) {
      PlaceSearchFailed(:final keywords) => keywords,
      PlaceSearchEmpty(:final keywords) => keywords,
      PlaceSearchLoaded(:final keywords) => keywords,
      _ => null,
    };
    if (keywords == null) return;
    await searchByKeywords(keywords, city: city);
  }

  void select(Place place) {
    if (_selected?.id == place.id) return;
    _selected = place;
    notifyListeners();
  }

  void clearSelection() {
    if (_selected == null) return;
    _selected = null;
    notifyListeners();
  }

  /// 响应是否已被更新的请求取代。
  bool _isStale(int requestId) => _isDisposed || requestId != _requestId;

  void _setState(PlaceSearchState state) {
    if (_isDisposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
