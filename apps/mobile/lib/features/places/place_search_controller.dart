import 'package:flutter/foundation.dart';

import 'place_models.dart';
import 'place_repository.dart';

/// 探索页的检索状态。
sealed class PlaceSearchState {
  const PlaceSearchState();
}

/// 尚未检索过。地图只显示底图。
final class PlaceSearchIdle extends PlaceSearchState {
  const PlaceSearchIdle();
}

final class PlaceSearchLoading extends PlaceSearchState {
  const PlaceSearchLoading(this.keywords);

  final String keywords;
}

final class PlaceSearchLoaded extends PlaceSearchState {
  const PlaceSearchLoaded({required this.keywords, required this.result});

  final String keywords;
  final PlaceSearchResult result;

  List<Place> get places => result.places;
}

/// 检索成功但无结果。
///
/// 与 [PlaceSearchFailed] 分开是刻意的：设计文档 §12 要求「没有符合条件的地点」
/// 与「数据源不可用」给出不同提示，合成一个状态就无法区分。
final class PlaceSearchEmpty extends PlaceSearchState {
  const PlaceSearchEmpty(this.keywords);

  final String keywords;
}

final class PlaceSearchFailed extends PlaceSearchState {
  const PlaceSearchFailed({
    required this.keywords,
    required this.message,
    required this.failure,
  });

  final String keywords;
  final String message;
  final PlaceSearchFailure failure;

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

  PlaceSearchState get state => _state;

  /// 当前选中的地点，决定详情面板是否展开。
  Place? get selected => _selected;

  bool get isLoading => _state is PlaceSearchLoading;

  Future<void> searchByKeywords(String keywords, {String? city}) async {
    final trimmed = keywords.trim();
    if (trimmed.isEmpty) return;

    final requestId = ++_requestId;
    // 新检索作废旧的选中项：详情面板里的地点可能已不在新结果中。
    _selected = null;
    _setState(PlaceSearchLoading(trimmed));

    try {
      final result = await _repository.searchByKeywords(
        keywords: trimmed,
        city: city,
      );
      if (_isStale(requestId)) return;
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
