import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/config/supabase_config.dart';
import 'package:savorseek/app/util/uuid.dart';
import 'package:savorseek/features/auth/auth_service.dart';

import 'trip_mapper.dart';
import 'trip_models.dart';

/// 单次读取所需的全部列。
///
/// 一次嵌套查询而非逐层拉取：分三次请求即是 N+1，且中途 revision 变化会读到
/// 不一致的快照。
const String _planSelect = '''
id, title, timezone, start_date, end_date, revision, updated_at,
trip_days(
  id, local_date, available_start_time, available_end_time, notes,
  trip_items(
    id, trip_day_id, item_type, place_id, title, planned_start_at,
    planned_end_at, time_slot, position, notes, status,
    is_place_locked, is_time_locked, is_order_locked
  )
)''';

abstract interface class TripRepository {
  Future<TripPlan?> loadPlan();
}

class InMemoryTripRepository implements TripRepository {
  const InMemoryTripRepository({this.plan});

  final TripPlan? plan;

  @override
  Future<TripPlan?> loadPlan() async => plan;
}

/// 后端不可用时的占位仓库。
///
/// 存在的意义是让「未注入 Supabase 参数」与「查询失败」走同一条 UI 错误分支，
/// 而不是在 Widget 树里散落 null 判断。
class UnavailableTripRepository implements TripRepository {
  const UnavailableTripRepository([this.message]);

  final String? message;

  @override
  Future<TripPlan?> loadPlan() async {
    throw TripRepositoryException(message ?? SupabaseConfig.missingMessage);
  }
}

/// 基于自建 Supabase 的行程仓库。
///
/// 读写路径不对称，这是本类的核心约束：`authenticated` 角色对三张表只有
/// `select`，insert/update/delete 已全部 revoke（见 itinerary_schema.sql:310），
/// 因此写入必须走 `security definer` RPC，直接 `.insert()` 必然被拒。
class SupabaseTripRepository implements TripRepository {
  SupabaseTripRepository({required this.auth, SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final AuthService auth;
  final SupabaseClient _client;

  @override
  Future<TripPlan?> loadPlan() async {
    _requireSession();
    try {
      // RLS 限定 user_id = auth.uid()，无需在客户端重复过滤。
      // 取最近更新的一条：当前 UI 只展示单个行程。
      final rows = await _client
          .from('trips')
          .select(_planSelect)
          .order('updated_at', ascending: false)
          .limit(1);
      if (rows.isEmpty) return null;
      final row = rows.first;
      final sorted = _sortNested(row);
      return TripMapper.planFromRow(sorted);
    } on PostgrestException catch (error) {
      throw _translate(error);
    } on SocketException catch (_) {
      throw const TripRepositoryException(
        '无法连接行程服务，请检查网络后重试。',
        kind: TripRepositoryErrorKind.network,
      );
    }
  }

  /// 创建行程，返回新行程的 id 与 revision。
  Future<TripWriteResult> createTrip({
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    String timezone = 'Asia/Shanghai',
    int partySize = 1,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('create_trip', {
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_title': title,
      'p_timezone': timezone,
      'p_start_date': _formatDate(startDate),
      'p_end_date': _formatDate(endDate),
      'p_party_size': partySize,
    });
    // create_trip 直接返回 trips 行，不带 revision 包装。
    return TripWriteResult(
      id: payload['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  /// 添加一天。[expectedRevision] 取自 `trips.revision`，不匹配时抛
  /// [TripRepositoryErrorKind.conflict]，调用方应重新读取后重试。
  Future<TripWriteResult> addTripDay({
    required String tripId,
    required int expectedRevision,
    required DateTime localDate,
    String? notes,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('add_trip_day', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_local_date': _formatDate(localDate),
      'p_notes': notes,
    });
    return TripWriteResult(
      id: (payload['trip_day'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  /// 添加一个行程项。时间以 UTC 序列化，服务端列为 timestamptz。
  ///
  /// 两类项的必填项互斥，由库端 trigger 强制（itinerary_schema.sql:236-262）：
  /// `place_visit` 必须同时带 [placeId] 与 [placeSnapshot]，`break` 两者都不能带。
  /// 违反时服务端返回 23514，因此在发请求前先本地断言，省一次往返。
  Future<TripWriteResult> addTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    TripStopType timeSlot = TripStopType.flexible,
    TripItemType itemType = TripItemType.placeVisit,
    int position = 0,
    String? placeId,
    PlaceSnapshot? placeSnapshot,
    String? notes,
    String? idempotencyKey,
  }) async {
    _requireSession();
    if (itemType == TripItemType.placeVisit) {
      if (placeId == null || placeSnapshot == null) {
        throw const TripRepositoryException('地点项必须同时提供 placeId 与地点快照。');
      }
    } else if (placeId != null || placeSnapshot != null) {
      throw const TripRepositoryException('休息项不能关联地点。');
    }
    final payload = await _rpc('add_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_day_id': tripDayId,
      'p_item_type': itemType.wireName,
      'p_place_id': placeId,
      'p_title': title,
      'p_planned_start_at': plannedStartAt.toUtc().toIso8601String(),
      'p_planned_end_at': plannedEndAt.toUtc().toIso8601String(),
      'p_time_slot': timeSlot.wireName,
      'p_position': position,
      'p_notes': notes,
      'p_place_snapshot': placeSnapshot?.toJson(),
    });
    return TripWriteResult(
      id: (payload['trip_item'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  Future<Map<String, dynamic>> _rpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    try {
      final result = await _client.rpc<dynamic>(name, params: params);
      if (result is Map<String, dynamic>) return result;
      throw TripRepositoryException('$name 返回了非预期的结果。');
    } on PostgrestException catch (error) {
      throw _translate(error);
    } on SocketException catch (_) {
      throw const TripRepositoryException(
        '无法连接行程服务，请检查网络后重试。',
        kind: TripRepositoryErrorKind.network,
      );
    }
  }

  void _requireSession() {
    if (!SupabaseConfig.isConfigured) {
      throw TripRepositoryException(SupabaseConfig.missingMessage);
    }
    if (!auth.isSignedIn) {
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );
    }
  }

  /// 嵌套关系无法用顶层 `.order()` 排序，PostgREST 的 referencedTable 排序在
  /// 深层嵌套下不稳定，故在客户端按 local_date / position 排一次。
  Map<String, dynamic> _sortNested(Map<String, dynamic> row) {
    final days = [...?(row['trip_days'] as List?)]
        .whereType<Map<String, dynamic>>()
        .map((day) {
          final items = [...?(day['trip_items'] as List?)]
              .whereType<Map<String, dynamic>>()
              // 已取消的项不参与展示，位置唯一约束也仅覆盖非取消项。
              .where((item) => item['status'] != 'cancelled')
              .toList()
            ..sort(_byPosition);
          return {...day, 'trip_items': items};
        })
        .toList()
      ..sort(
        (a, b) =>
            (a['local_date'] as String).compareTo(b['local_date'] as String),
      );
    return {...row, 'trip_days': days};
  }

  static int _byPosition(Map<String, dynamic> a, Map<String, dynamic> b) {
    final byPosition = ((a['position'] as num?) ?? 0).compareTo(
      (b['position'] as num?) ?? 0,
    );
    if (byPosition != 0) return byPosition;
    return (a['planned_start_at'] as String).compareTo(
      b['planned_start_at'] as String,
    );
  }

  static String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

/// 把 PostgREST / RPC 错误码映射到 UI 已有的分支。
///
/// 错误码与 itinerary_rpcs.sql 中 `raise exception using errcode` 一致：
/// 28000 未认证、42501 无权限或不存在、40001 revision 冲突。
TripRepositoryException translatePostgrestError({
  required String? code,
  required String message,
}) {
  return switch (code) {
    '28000' || 'PGRST301' => const TripRepositoryException(
      '登录状态已失效，请重新登录。',
      kind: TripRepositoryErrorKind.unauthenticated,
    ),
    // P0002 是 RPC 显式抛出的 revision 冲突。40001 保留：真正的串行化失败也
    // 应让用户重新加载后重试，处置方式与前者一致。
    'P0002' || '40001' => const TripRepositoryException(
      '行程已被其他操作更新，请重新加载后再试。',
      kind: TripRepositoryErrorKind.conflict,
    ),
    '42501' => const TripRepositoryException(
      '没有权限访问该行程。',
      kind: TripRepositoryErrorKind.unauthenticated,
    ),
    _ => TripRepositoryException(message),
  };
}

TripRepositoryException _translate(PostgrestException error) =>
    translatePostgrestError(code: error.code, message: error.message);

/// 写入行程项时随附的地点快照。
///
/// 库端 trigger 会逐项校验（itinerary_schema.sql:243-259）：`schema_version`
/// 必须为 1，`name` 非空，经纬度必须同时给出或同时省略，给出时须落在合法范围
/// 且 `coordinate_system` 为 gcj02 或 wgs84。快照的意义是把当时的地点信息固化
/// 下来，即使源地点后续变更，已排入行程的内容也不会漂移。
@immutable
class PlaceSnapshot {
  const PlaceSnapshot({
    required this.name,
    this.latitude,
    this.longitude,
    this.coordinateSystem = PlaceCoordinateSystem.gcj02,
  }) : assert(
         (latitude == null) == (longitude == null),
         '经纬度必须同时提供或同时省略',
       );

  static const int schemaVersion = 1;

  final String name;
  final double? latitude;
  final double? longitude;

  /// 坐标系。高德返回 gcj02，故取其为默认值。
  final PlaceCoordinateSystem coordinateSystem;

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      'name': name,
      if (latitude != null) ...{
        'latitude': latitude,
        'longitude': longitude,
        'coordinate_system': coordinateSystem.wireName,
      },
    };
  }
}

enum PlaceCoordinateSystem {
  gcj02('gcj02'),
  wgs84('wgs84');

  const PlaceCoordinateSystem(this.wireName);

  final String wireName;
}

@immutable
class TripWriteResult {
  const TripWriteResult({required this.id, required this.revision});

  final String id;

  /// 写入后行程的最新 revision，供后续写入作为 expectedRevision。
  final int revision;
}

class TripRepositoryException implements Exception {
  const TripRepositoryException(this.message, {this.kind = TripRepositoryErrorKind.unavailable});

  final String message;
  final TripRepositoryErrorKind kind;

  @override
  String toString() => message;
}

enum TripRepositoryErrorKind { unavailable, unauthenticated, network, conflict }

class DemoTripRepository implements TripRepository {
  const DemoTripRepository();

  @override
  Future<TripPlan?> loadPlan() async {
    final day = DateTime(2026, 8, 22);
    return TripPlan(
      id: 'demo-shanghai-food-day',
      title: '上海一日寻味',
      destination: '上海 · 徐汇与静安',
      mapState: TripMapState.unavailable,
      updatedAt: DateTime(2026, 8, 21, 18),
      days: [
        TripDay(
          date: day,
          label: '周六 · 8 月 22 日',
          stops: [
            TripStop(
              id: 'breakfast',
              title: '老城隍庙小笼',
              subtitle: '早餐 · 08:30–09:30',
              startAt: DateTime(2026, 8, 22, 8, 30),
              endAt: DateTime(2026, 8, 22, 9, 30),
              type: TripStopType.breakfast,
              note: '建议先取号，再沿福佑路慢慢逛过去。',
            ),
            TripStop(
              id: 'lunch',
              title: '本帮菜午餐',
              subtitle: '午餐 · 12:00–13:30',
              startAt: DateTime(2026, 8, 22, 12),
              endAt: DateTime(2026, 8, 22, 13, 30),
              type: TripStopType.lunch,
              isLocked: true,
              note: '已锁定：保留给第一次来上海的本帮菜体验。',
            ),
            TripStop(
              id: 'snack',
              title: '安福路咖啡与甜点',
              subtitle: '下午茶 · 15:00–16:30',
              startAt: DateTime(2026, 8, 22, 15),
              endAt: DateTime(2026, 8, 22, 16, 30),
              type: TripStopType.afternoonTea,
              note: '留出步行时间，按现场排队情况灵活调整。',
            ),
            TripStop(
              id: 'dinner',
              title: '夜宵：生煎与排骨年糕',
              subtitle: '晚餐 · 18:30–20:00',
              startAt: DateTime(2026, 8, 22, 18, 30),
              endAt: DateTime(2026, 8, 22, 20),
              type: TripStopType.dinner,
            ),
          ],
        ),
      ],
    );
  }
}

@immutable
class TripPlanSummary {
  const TripPlanSummary({required this.plan});

  final TripPlan plan;

  int get stopCount => plan.stopCount;

  Duration get plannedDuration {
    if (plan.days.isEmpty || plan.days.first.stops.isEmpty) {
      return Duration.zero;
    }
    final stops = plan.days.expand((day) => day.stops).toList(growable: false);
    final start = stops.map((stop) => stop.startAt).reduce((a, b) => a.isBefore(b) ? a : b);
    final end = stops.map((stop) => stop.endAt).reduce((a, b) => a.isAfter(b) ? a : b);
    return end.difference(start);
  }

  double get dayCount => math.max(plan.days.length, 1).toDouble();
}
