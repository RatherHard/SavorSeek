import 'package:flutter/foundation.dart';

import 'trip_models.dart';
import 'trip_repository.dart';

sealed class TripViewState {
  const TripViewState();
}

final class TripLoading extends TripViewState {
  const TripLoading();
}

final class TripEmpty extends TripViewState {
  const TripEmpty();
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

class TripController extends ChangeNotifier {
  TripController(this._repository);

  final TripRepository _repository;
  TripViewState _state = const TripLoading();
  bool _isDisposed = false;

  TripViewState get state => _state;

  Future<void> load() async {
    _setState(const TripLoading());
    try {
      final plan = await _repository.loadPlan();
      if (plan == null) {
        _setState(const TripEmpty());
      } else {
        _setState(TripLoaded(plan));
      }
    } on TripRepositoryException catch (error) {
      _setState(TripError(error.message, kind: error.kind));
    } on Exception {
      _setState(const TripError('行程服务暂时不可用，请稍后重试。'));
    }
  }

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
