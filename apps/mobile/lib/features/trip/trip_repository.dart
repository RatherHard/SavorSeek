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
    is_place_locked, is_time_locked, is_order_locked, place_snapshot
  )
)''';

/// 行程页可执行的写入能力。
///
/// 抽成接口而非让 UI 依赖 [SupabaseTripRepository]：Widget 测试无法初始化
/// Supabase，只有依赖可替换才能覆盖改期的成功、冲突与失败分支。
abstract interface class TripWriter {
  Future<TripWriteResult> rescheduleTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String tripDayId,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? idempotencyKey,
  });

  /// 取消行程项（软删除）。记录与快照保留，可经 [restoreTripItem] 恢复。
  Future<TripWriteResult> cancelTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  });

  /// 把已取消的项恢复为待安排。
  Future<TripWriteResult> restoreTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  });

  /// 彻底删除行程项。不可恢复，调用方须先向用户确认。
  Future<int> deleteTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  });

  /// 更改行程时区。已排入的项保留当地钟点，UTC 时刻由服务端重算。
  Future<int> changeTripTimezone({
    required String tripId,
    required int expectedRevision,
    required String timezone,
    String? idempotencyKey,
  });

  /// 添加一个自由安排节点（`break`）。
  ///
  /// 只暴露 `break` 这一种：地点项必须携带 placeId 与快照（库端 trigger 强制），
  /// 而行程页没有地点检索能力，地点节点仍从探索页加入。
  Future<TripWriteResult> addBreakItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? notes,
    String? idempotencyKey,
  });

  /// 统计某一天已有的非取消项数，用于推导新节点的 position。
  Future<int> countItemsOnDay(String tripDayId);

  /// 批量取消（软删除）。整批原子：任一项不合法则全部不生效。
  ///
  /// 单独的 RPC 而非循环调用单项版本：每次单项写入都会递增 revision，循环到
  /// 第二次时 expected_revision 已过期，必然收到 P0002。
  Future<TripBatchResult> batchCancelTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  });

  /// 批量硬删除。不可恢复，调用方须先向用户确认。
  Future<TripBatchResult> batchDeleteTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  });
}

/// 批量写入的结果。
@immutable
class TripBatchResult {
  const TripBatchResult({required this.affectedCount, required this.revision});

  /// 实际受影响的项数。
  final int affectedCount;

  /// 写入后行程的最新 revision。批量只递增一次，故这里恒为原值 +1。
  final int revision;
}

abstract interface class TripRepository {
  /// 读取一个行程的完整内容。
  ///
  /// [tripId] 为空时取最近更新的那一个——首次进入行程页时还没有选中项，需要有
  /// 一个确定的默认值。
  Future<TripPlan?> loadPlan({String? tripId});

  /// 列出用户的全部行程，按最近更新排序。
  ///
  /// 只取列表所需的字段，不含嵌套的日期与项：切换器只显示标题与日期区间，
  /// 为此拉全部行程的全部项会让请求量随行程数线性膨胀。
  Future<List<TripSummary>> listTrips();
}

/// 预算口径，对应 `trips.budget_scope`。
enum TripBudgetScope {
  perPerson('per_person'),
  total('total');

  const TripBudgetScope(this.wireName);

  final String wireName;
}

/// 行程列表项。不含日期与行程项，仅够渲染切换器。
@immutable
class TripSummary {
  const TripSummary({
    required this.id,
    required this.title,
    required this.startDate,
    required this.endDate,
    this.timezone = 'Asia/Shanghai',
    this.updatedAt,
  });

  final String id;
  final String title;

  /// 行程时区下的起止自然日。
  final DateTime startDate;
  final DateTime endDate;
  final String timezone;
  final DateTime? updatedAt;

  /// 行程横跨的天数，含首尾两端。
  int get dayCount => endDate.difference(startDate).inDays + 1;
}

class InMemoryTripRepository implements TripRepository {
  const InMemoryTripRepository({this.plan});

  final TripPlan? plan;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async => plan;

  @override
  Future<List<TripSummary>> listTrips() async {
    final current = plan;
    if (current == null) return const [];
    return [
      TripSummary(
        id: current.id,
        title: current.title,
        startDate: current.days.isEmpty
            ? DateTime.now()
            : current.days.first.date,
        endDate: current.days.isEmpty ? DateTime.now() : current.days.last.date,
        timezone: current.timezone,
        updatedAt: current.updatedAt,
      ),
    ];
  }
}

/// 后端不可用时的占位仓库。
///
/// 存在的意义是让「未注入 Supabase 参数」与「查询失败」走同一条 UI 错误分支，
/// 而不是在 Widget 树里散落 null 判断。
class UnavailableTripRepository implements TripRepository {
  const UnavailableTripRepository([this.message]);

  final String? message;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    throw TripRepositoryException(message ?? SupabaseConfig.missingMessage);
  }

  @override
  Future<List<TripSummary>> listTrips() async {
    throw TripRepositoryException(message ?? SupabaseConfig.missingMessage);
  }
}

/// 基于自建 Supabase 的行程仓库。
///
/// 读写路径不对称，这是本类的核心约束：`authenticated` 角色对三张表只有
/// `select`，insert/update/delete 已全部 revoke（见 itinerary_schema.sql:310），
/// 因此写入必须走 `security definer` RPC，直接 `.insert()` 必然被拒。
class SupabaseTripRepository implements TripRepository, TripWriter {
  SupabaseTripRepository({required this.auth, SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final AuthService auth;
  final SupabaseClient _client;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    _requireSession();
    try {
      // RLS 限定 user_id = auth.uid()，无需在客户端重复过滤。
      // 未指定 tripId 时取最近更新的一条作为默认选中项。
      final query = _client.from('trips').select(_planSelect);
      final rows = tripId == null
          ? await query.order('updated_at', ascending: false).limit(1)
          : await query.eq('id', tripId).limit(1);
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

  @override
  Future<List<TripSummary>> listTrips() async {
    _requireSession();
    try {
      final rows = await _client
          .from('trips')
          .select('id, title, timezone, start_date, end_date, updated_at')
          .order('updated_at', ascending: false);
      return rows
          .map(
            (row) => TripSummary(
              id: row['id'] as String,
              title: (row['title'] as String?) ?? '未命名行程',
              startDate: DateTime.parse(row['start_date'] as String),
              endDate: DateTime.parse(row['end_date'] as String),
              timezone: (row['timezone'] as String?) ?? 'Asia/Shanghai',
              updatedAt: row['updated_at'] is String
                  ? DateTime.tryParse(row['updated_at'] as String)
                  : null,
            ),
          )
          .toList(growable: false);
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
  ///
  /// [budgetLimitMinor] 与 [budgetScope] 必须同时给出或同时省略：库端约束
  /// `trips_budget_scope_ck` 要求两者共存亡，只给其一会被拒。
  Future<TripWriteResult> createTrip({
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    String timezone = 'Asia/Shanghai',
    int partySize = 1,
    int? budgetLimitMinor,
    TripBudgetScope budgetScope = TripBudgetScope.total,
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
      'p_budget_limit_minor': budgetLimitMinor,
      // 预算为空时 scope 也必须为空，否则触发 trips_budget_scope_ck。
      'p_budget_scope': budgetLimitMinor == null ? null : budgetScope.wireName,
    });
    // create_trip 直接返回 trips 行，不带 revision 包装。
    return TripWriteResult(
      id: payload['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  /// 创建行程并按日期区间补齐每一天。
  ///
  /// 两次 RPC 之间没有事务包裹，因此幂等键必须由调用方复用：网络中断后重试时，
  /// 同一把键会命中 `trip_idempotency_keys` 返回原结果，而不是创建第二个行程。
  /// 键在首次调用时生成并缓存于 [keys]，重试请传入同一个实例。
  ///
  /// 逐天调用 `add_trip_day` 且每次都用上一次返回的 revision：该 RPC 会把
  /// `trips.revision` 自增，沿用旧值会在第二天触发 P0002 冲突。
  Future<TripWriteResult> createTripWithDays({
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    required CreateTripKeys keys,
    int partySize = 1,
    int? budgetLimitMinor,
    String timezone = 'Asia/Shanghai',
  }) async {
    final created = await createTrip(
      title: title,
      startDate: startDate,
      endDate: endDate,
      timezone: timezone,
      partySize: partySize,
      budgetLimitMinor: budgetLimitMinor,
      idempotencyKey: keys.trip,
    );

    var revision = created.revision;
    final dayCount = endDate.difference(startDate).inDays + 1;
    for (var offset = 0; offset < dayCount; offset++) {
      final result = await addTripDay(
        tripId: created.id,
        expectedRevision: revision,
        localDate: startDate.add(Duration(days: offset)),
        idempotencyKey: keys.dayKeyAt(offset),
      );
      revision = result.revision;
    }

    return TripWriteResult(id: created.id, revision: revision);
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

  /// 改期：调整行程项的日期、时间与时段。
  ///
  /// 允许跨天移动（[tripDayId] 传目标日）。不接受 position 参数：跨天后的新位置
  /// 由服务端按目标日实际占用计算，客户端算出的值在并发下必然过期。
  ///
  /// 时间必须已按行程时区折算（见 `TripTimeZone.toInstant`）：库端校验开始时刻
  /// 折回行程时区后的日期须等于目标日的 local_date，不符返回 23514。
  @override
  Future<TripWriteResult> rescheduleTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String tripDayId,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('reschedule_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_id': tripItemId,
      'p_trip_day_id': tripDayId,
      'p_planned_start_at': plannedStartAt.toUtc().toIso8601String(),
      'p_planned_end_at': plannedEndAt.toUtc().toIso8601String(),
      'p_time_slot': timeSlot.wireName,
    });
    return TripWriteResult(
      id: (payload['trip_item'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  @override
  Future<TripWriteResult> cancelTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('cancel_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_id': tripItemId,
    });
    return TripWriteResult(
      id: (payload['trip_item'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  @override
  Future<TripWriteResult> restoreTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('restore_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_id': tripItemId,
    });
    return TripWriteResult(
      id: (payload['trip_item'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  /// 返回删除后行程的最新 revision。不返回项本身——它已经不存在了。
  @override
  Future<int> deleteTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('delete_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_id': tripItemId,
    });
    return (payload['revision'] as num).toInt();
  }

  /// 返回受影响的行程项数。
  @override
  Future<int> changeTripTimezone({
    required String tripId,
    required int expectedRevision,
    required String timezone,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('change_trip_timezone', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_timezone': timezone,
    });
    return (payload['items_shifted'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<TripBatchResult> batchCancelTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) => _batch(
    'batch_cancel_trip_items',
    countKey: 'cancelled_count',
    tripId: tripId,
    expectedRevision: expectedRevision,
    tripItemIds: tripItemIds,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<TripBatchResult> batchDeleteTripItems({
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) => _batch(
    'batch_delete_trip_items',
    countKey: 'deleted_count',
    tripId: tripId,
    expectedRevision: expectedRevision,
    tripItemIds: tripItemIds,
    idempotencyKey: idempotencyKey,
  );

  /// 两个批量 RPC 的形状完全相同，只有函数名与计数字段不同。
  Future<TripBatchResult> _batch(
    String function, {
    required String countKey,
    required String tripId,
    required int expectedRevision,
    required List<String> tripItemIds,
    String? idempotencyKey,
  }) async {
    _requireSession();
    if (tripItemIds.isEmpty) {
      throw const TripRepositoryException('请先选择要操作的行程项。');
    }
    final payload = await _rpc(function, {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_ids': tripItemIds,
    });
    return TripBatchResult(
      affectedCount: (payload[countKey] as num?)?.toInt() ?? 0,
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

  /// 读取「最近更新的行程」的排期上下文：行程本身加上它的全部日期。
  ///
  /// 为什么不复用 [loadPlan]：`TripPlan` 是展示模型，不含 `revision` 与
  /// `trip_days.id`，而 `add_trip_item` 两者都必需。这里单独取最小字段集，避免
  /// 为了一次写入把并发控制字段渗进 UI 模型。
  ///
  /// 返回 null 表示用户还没有行程或行程还没有任何一天，调用方应引导其先创建。
  Future<TripSchedulingContext?> findSchedulingContext() async {
    _requireSession();
    try {
      final rows = await _client
          .from('trips')
          .select(
            'id, revision, timezone, start_date, end_date, '
            'trip_days(id, local_date)',
          )
          .order('updated_at', ascending: false)
          .limit(1);
      if (rows.isEmpty) return null;
      final row = rows.first;
      final days =
          [...?(row['trip_days'] as List?)]
              .whereType<Map<String, dynamic>>()
              .map(
                (day) => TripDayRef(
                  id: day['id'] as String,
                  localDate: DateTime.parse(day['local_date'] as String),
                ),
              )
              .toList()
            ..sort((a, b) => a.localDate.compareTo(b.localDate));
      if (days.isEmpty) return null;
      return TripSchedulingContext(
        tripId: row['id'] as String,
        revision: (row['revision'] as num).toInt(),
        timezone: row['timezone'] as String,
        days: days,
      );
    } on PostgrestException catch (error) {
      throw _translate(error);
    } on SocketException catch (_) {
      throw const TripRepositoryException(
        '无法连接行程服务，请检查网络后重试。',
        kind: TripRepositoryErrorKind.network,
      );
    }
  }

  /// 添加一个自由安排节点。position 由调用方经 [countItemsOnDay] 推导后传入。
  @override
  Future<TripWriteResult> addBreakItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? notes,
    String? idempotencyKey,
  }) async {
    final position = await countItemsOnDay(tripDayId);
    return addTripItem(
      tripId: tripId,
      expectedRevision: expectedRevision,
      tripDayId: tripDayId,
      title: title,
      plannedStartAt: plannedStartAt,
      plannedEndAt: plannedEndAt,
      timeSlot: timeSlot,
      itemType: TripItemType.break_,
      position: position,
      notes: notes,
      idempotencyKey: idempotencyKey,
    );
  }

  /// 统计某一天已有的行程项数，用于推导新项的 position。
  ///
  /// `trip_items` 对 (trip_day_id, position) 有唯一约束（仅非取消项，见
  /// itinerary_schema.sql:111），position 固定传 0 会在第二次加入时冲突。
  @override
  Future<int> countItemsOnDay(String tripDayId) async {
    _requireSession();
    try {
      final rows = await _client
          .from('trip_items')
          .select('id, status')
          .eq('trip_day_id', tripDayId);
      return rows.where((row) => row['status'] != 'cancelled').length;
    } on PostgrestException catch (error) {
      throw _translate(error);
    } on SocketException catch (_) {
      throw const TripRepositoryException(
        '无法连接行程服务，请检查网络后重试。',
        kind: TripRepositoryErrorKind.network,
      );
    }
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
    final days =
        [...?(row['trip_days'] as List?)].whereType<Map<String, dynamic>>().map(
          (day) {
            // 已取消的项仍要展示：用户决策（2026-08-24）是软删除后可见且可恢复，
            // 过滤掉就没有恢复入口了。排序时沉到当天末尾——它们不占 position
            // （唯一索引排除 cancelled），混在中间会打乱可执行项的顺序感。
            final items = [
              ...?(day['trip_items'] as List?),
            ].whereType<Map<String, dynamic>>().toList()..sort(_byPosition);
            return {...day, 'trip_items': items};
          },
        ).toList()..sort(
          (a, b) =>
              (a['local_date'] as String).compareTo(b['local_date'] as String),
        );
    return {...row, 'trip_days': days};
  }

  static int _byPosition(Map<String, dynamic> a, Map<String, dynamic> b) {
    // 已取消的项一律排在后面：它们不参与 position 排序（唯一索引排除 cancelled），
    // 按 position 混排会让两个不同的项显示为同一位置。
    final aCancelled = a['status'] == 'cancelled';
    final bCancelled = b['status'] == 'cancelled';
    if (aCancelled != bCancelled) return aCancelled ? 1 : -1;

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
  }) : assert((latitude == null) == (longitude == null), '经纬度必须同时提供或同时省略');

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

/// 创建行程一次操作所用的幂等键集合。
///
/// 存在的意义是让重试可安全进行：`create_trip` 与逐天的 `add_trip_day` 是多次
/// 独立 RPC，任一步之后中断，重试都必须复用同一批键，否则会创建出重复行程或
/// 重复日期。持有同一实例即可重试。
class CreateTripKeys {
  CreateTripKeys({String? tripKey}) : trip = tripKey ?? generateUuidV4();

  final String trip;
  final Map<int, String> _dayKeys = {};

  /// 第 [offset] 天的幂等键，按需生成后固定不变。
  String dayKeyAt(int offset) => _dayKeys.putIfAbsent(offset, generateUuidV4);
}

/// 行程中的一天，供排期时选择。
@immutable
class TripDayRef {
  const TripDayRef({required this.id, required this.localDate});

  final String id;

  /// 该天在行程时区下的日期。
  final DateTime localDate;
}

/// 写入行程项所需的排期上下文。
@immutable
class TripSchedulingContext {
  const TripSchedulingContext({
    required this.tripId,
    required this.revision,
    required this.timezone,
    required this.days,
  });

  final String tripId;

  /// 乐观并发控制的期望修订号，作为 `add_trip_item` 的 `p_expected_revision`。
  final int revision;

  /// 行程时区。库端 trigger 会校验「项的开始时刻按此时区折算后的日期」必须等于
  /// 所属 trip_day 的 local_date（itinerary_schema.sql:232），因此排时间时不能
  /// 用设备本地时区。
  final String timezone;

  /// 行程的全部日期，已按 local_date 升序。
  ///
  /// 时间选择只能落在这些日期上：库端约束要求项归属的那一天必须已存在，
  /// 任意日期会被 trigger 拒绝。
  final List<TripDayRef> days;

  DateTime get firstDate => days.first.localDate;
  DateTime get lastDate => days.last.localDate;

  /// 找出某个日期对应的行程日。不存在时返回 null。
  TripDayRef? dayOn(DateTime localDate) {
    for (final day in days) {
      if (day.localDate.year == localDate.year &&
          day.localDate.month == localDate.month &&
          day.localDate.day == localDate.day) {
        return day;
      }
    }
    return null;
  }
}

@immutable
class TripWriteResult {
  const TripWriteResult({required this.id, required this.revision});

  final String id;

  /// 写入后行程的最新 revision，供后续写入作为 expectedRevision。
  final int revision;
}

class TripRepositoryException implements Exception {
  const TripRepositoryException(
    this.message, {
    this.kind = TripRepositoryErrorKind.unavailable,
  });

  final String message;
  final TripRepositoryErrorKind kind;

  @override
  String toString() => message;
}

enum TripRepositoryErrorKind { unavailable, unauthenticated, network, conflict }

class DemoTripRepository implements TripRepository {
  const DemoTripRepository();

  @override
  Future<List<TripSummary>> listTrips() async {
    final plan = await loadPlan();
    if (plan == null) return const [];
    return [
      TripSummary(
        id: plan.id,
        title: plan.title,
        startDate: plan.days.first.date,
        endDate: plan.days.last.date,
        timezone: plan.timezone,
        updatedAt: plan.updatedAt,
      ),
    ];
  }

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
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
    final start = stops
        .map((stop) => stop.startAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final end = stops
        .map((stop) => stop.endAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    return end.difference(start);
  }

  double get dayCount => math.max(plan.days.length, 1).toDouble();
}
