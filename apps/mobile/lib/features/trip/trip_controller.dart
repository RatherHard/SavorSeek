import 'package:flutter/foundation.dart';

import 'trip_models.dart';
import 'trip_repository.dart';

sealed class TripViewState {
  const TripViewState();
}

final class TripLoading extends TripViewState {
  const TripLoading();
}

/// 目标行程已不存在。
///
/// 与「用户没有任何行程」不同，故不复用一个笼统的空态：详情页只服务一个已知
/// 的 tripId，读不到只可能是它没了——可能是另一台设备删的，也可能列表数据已
/// 过期。此时显示「暂无行程」是误导，应提示「此行程已不存在」并给出返回列表的
/// 出口。「你还没有行程」这一情形由列表页的 TripListEmpty 负责。
final class TripDetailGone extends TripViewState {
  const TripDetailGone();
}

final class TripLoaded extends TripViewState {
  const TripLoaded(this.plan);

  final TripPlan plan;
}

final class TripError extends TripViewState {
  const TripError(
    this.message, {
    this.kind = TripRepositoryErrorKind.unavailable,
  });

  final String message;

  /// 错误类别，决定 UI 给出的下一步动作（未认证→登录，冲突→重新加载）。
  final TripRepositoryErrorKind kind;
}

/// 单个行程的详情控制器（二级页面）。
///
/// 只服务构造时传入的那一个行程：行程的选择由一级页面的 TripListController
/// 负责，因此这里不再持有行程列表，也没有切换能力。少一次 listTrips 请求，
/// 且「在看哪一个」由导航栈本身表达，无需状态字段。
class TripController extends ChangeNotifier {
  TripController(this._repository, {required this.tripId});

  final TripRepository _repository;

  /// 本控制器服务的行程 id，构造后不变。
  final String tripId;

  TripViewState _state = const TripLoading();
  bool _isDisposed = false;
  int _loadGeneration = 0;

  TripViewState get state => _state;

  Future<void> load() async {
    final generation = ++_loadGeneration;
    _setState(const TripLoading());
    try {
      final plan = await _repository.loadPlan(tripId: tripId);
      if (!_isCurrent(generation)) return;
      // null 意味着这个行程没了，而不是用户没有行程——详情页据此提示并给出返回出口。
      _setState(plan == null ? const TripDetailGone() : TripLoaded(plan));
    } on TripRepositoryException catch (error) {
      if (!_isCurrent(generation)) return;
      _setState(TripError(error.message, kind: error.kind));
    } on Exception {
      if (!_isCurrent(generation)) return;
      _setState(const TripError('行程服务暂时不可用，请稍后重试。'));
    }
  }

  bool _isCurrent(int generation) =>
      !_isDisposed && generation == _loadGeneration;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _setState(TripViewState state) {
    if (_isDisposed) return;
    _state = state;
    notifyListeners();
  }
}
