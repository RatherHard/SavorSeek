import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/supabase/supabase_bootstrap.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/agent/agent_repository.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/trip/add_place_to_trip.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_repository_fakes.dart';
import 'package:savorseek/features/trip/trip_route_service.dart';

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
    this.favoriteRepository = const UnavailableFavoriteRepository(),
    this.scheduler,
    this.bootstrapMessage,
    this.mapConsent,
    this.routeService,
    this.agentRepository = const UnavailableAgentRepository(),
    this.supabaseClient,
  });

  /// 由已完成的 Supabase 初始化结果组装真实依赖。
  ///
  /// 初始化失败时仍返回可用对象：认证入口置灰、行程页给出明确原因，
  /// 而不是让整个应用无法启动。
  factory AppDependencies.fromBootstrap(SupabaseBootstrapResult result) {
    // 同意状态与后端是否就绪无关：地图在离线兜底下也要能显示，故两条分支
    // 都注入同一种实例。
    final consent = AmapConsent();
    if (!result.isReady) {
      return AppDependencies(
        auth: UnavailableAuthService(result.message),
        tripRepository: UnavailableTripRepository(result.message),
        placeRepository: UnavailablePlaceRepository(result.message),
        favoriteRepository: UnavailableFavoriteRepository(result.message),
        bootstrapMessage: result.message,
        mapConsent: consent,
        agentRepository: UnavailableAgentRepository(result.message),
        supabaseClient: null,
      );
    }
    final auth = SupabaseAuthService();
    final tripRepository = SupabaseTripRepository(auth: auth);
    return AppDependencies(
      auth: auth,
      tripRepository: tripRepository,
      placeRepository: SupabasePlaceRepository(auth: auth),
      favoriteRepository: SupabaseFavoriteRepository(auth: auth),
      scheduler: AddPlaceToTrip(tripRepository),
      mapConsent: consent,
      routeService: EdgeFunctionRouteService(auth: auth),
      agentRepository: SupabaseAgentRepository(auth: auth),
      supabaseClient: Supabase.instance.client,
    );
  }

  final AuthService auth;
  final TripRepository tripRepository;
  final PlaceRepository placeRepository;
  final FavoriteRepository favoriteRepository;

  /// 把地点加入行程的能力。未接入后端时为空，探索页据此禁用按钮。
  final PlaceScheduler? scheduler;

  /// 高德隐私政策同意状态。
  ///
  /// 提到应用级是因为探索页与行程页都要显示地图：留在页面内会让用户在两处
  /// 各同意一次，而同意与否本是同一个事实。为空时由页面各自新建（仅测试与
  /// 离线兜底会走到，此时两页不共享无实际影响）。
  final AmapConsent? mapConsent;

  /// 真实路网路线来源。为空时行程地图退化为直线连接。
  final TripRouteService? routeService;

  final AgentRepository agentRepository;
  final SupabaseClient? supabaseClient;

  /// 初始化未成功时面向用户的原因；成功时为 null。
  final String? bootstrapMessage;

  bool get isBackendReady => bootstrapMessage == null;
}
