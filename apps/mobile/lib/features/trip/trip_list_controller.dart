import 'package:flutter/foundation.dart';

import 'trip_repository.dart';

/// 行程列表的视图状态。
sealed class TripListState {
  const TripListState();
}

final class TripListLoading extends TripListState {
  const TripListLoading();
}

/// 没有任何行程，引导用户创建第一个。
final class TripListEmpty extends TripListState {
  const TripListEmpty();
}

final class TripListLoaded extends TripListState {
  const TripListLoaded(this.trips);

  final List<TripSummary> trips;
}

final class TripListError extends TripListState {
  const TripListError(
    this.message, {
    this.kind = TripRepositoryErrorKind.unavailable,
  });

  final String message;

  /// 错误类别，决定 UI 给出的下一步动作（未认证→登录）。
  final TripRepositoryErrorKind kind;
}

/// 行程列表控制器（一级页面）。
///
/// 只取摘要不取行程项：列表页只显示标题与日期区间，为此把每个行程的全部节点
/// 都拉下来会让请求量随行程数线性膨胀。节点由详情页按需加载。
class TripListController extends ChangeNotifier {
  TripListController(this._repository);

  final TripRepository _repository;
  TripListState _state = const TripListLoading();
  bool _isDisposed = false;

  TripListState get state => _state;

  Future<void> load() async {
    _setState(const TripListLoading());
    try {
      final trips = await _repository.listTrips();
      _setState(trips.isEmpty ? const TripListEmpty() : TripListLoaded(trips));
    } on TripRepositoryException catch (error) {
      _setState(TripListError(error.message, kind: error.kind));
    } on Exception {
      _setState(const TripListError('行程服务暂时不可用，请稍后重试。'));
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _setState(TripListState state) {
    if (_isDisposed) return;
    _state = state;
    notifyListeners();
  }
}
