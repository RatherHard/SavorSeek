import 'package:flutter/foundation.dart';

import 'package:savorseek/app/supabase/supabase_bootstrap.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/trip/add_place_to_trip.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

/// 应用级依赖集合，在 `runApp` 前一次性组装。
///
/// 用构造注入而非全局单例：Widget 测试无法调用 `Supabase.initialize`，只有
/// 依赖可替换才能在不联网的前提下覆盖登录与行程读取的全部分支。
@immutable
class AppDependencies {
  const AppDependencies({
    required this.auth,
    required this.tripRepository,
    this.placeRepository = const UnavailablePlaceRepository(),
    this.onAddPlaceToTrip,
    this.bootstrapMessage,
  });

  /// 由已完成的 Supabase 初始化结果组装真实依赖。
  ///
  /// 初始化失败时仍返回可用对象：认证入口置灰、行程页给出明确原因，
  /// 而不是让整个应用无法启动。
  factory AppDependencies.fromBootstrap(SupabaseBootstrapResult result) {
    if (!result.isReady) {
      return AppDependencies(
        auth: UnavailableAuthService(result.message),
        tripRepository: UnavailableTripRepository(result.message),
        placeRepository: UnavailablePlaceRepository(result.message),
        bootstrapMessage: result.message,
      );
    }
    final auth = SupabaseAuthService();
    final tripRepository = SupabaseTripRepository(auth: auth);
    return AppDependencies(
      auth: auth,
      tripRepository: tripRepository,
      placeRepository: SupabasePlaceRepository(auth: auth),
      onAddPlaceToTrip: AddPlaceToTrip(tripRepository).call,
    );
  }

  final AuthService auth;
  final TripRepository tripRepository;
  final PlaceRepository placeRepository;

  /// 把地点加入行程。未接入后端时为空，探索页据此禁用按钮。
  final Future<void> Function(Place place)? onAddPlaceToTrip;

  /// 初始化未成功时面向用户的原因；成功时为 null。
  final String? bootstrapMessage;

  bool get isBackendReady => bootstrapMessage == null;
}
