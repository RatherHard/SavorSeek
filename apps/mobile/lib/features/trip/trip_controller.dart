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
  const TripLoaded(this.plan, {this.trips = const []});

  final TripPlan plan;

  /// 用户的全部行程，供切换器展示。只有一个行程时 UI 可据此隐藏切换入口。
  final List<TripSummary> trips;
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

  /// 当前选中的行程 id。为空时 [load] 取最近更新的那一个。
  String? _selectedTripId;

  TripViewState get state => _state;

  /// 当前选中的行程 id，未选中时为 null。
  String? get selectedTripId => _selectedTripId;

  /// 切换到指定行程并重新加载。
  Future<void> selectTrip(String tripId) async {
    if (tripId == _selectedTripId) return;
    _selectedTripId = tripId;
    await load();
  }

  Future<void> load() async {
    _setState(const TripLoading());
    try {
      // 先取列表：选中的行程若已不存在，据此可回退到另一个行程，
      // 而不是让页面停在「暂无行程」。
      final trips = await _repository.listTrips();
      // 选中项失效时回退到默认：删除当前行程后仍指向它会读到空结果，
      // 表现为「明明还有行程却显示暂无行程」。
      if (_selectedTripId != null &&
          !trips.any((trip) => trip.id == _selectedTripId)) {
        _selectedTripId = null;
      }
      final plan = await _repository.loadPlan(tripId: _selectedTripId);
      if (plan == null) {
        _setState(const TripEmpty());
      } else {
        _selectedTripId = plan.id;
        _setState(TripLoaded(plan, trips: trips));
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
