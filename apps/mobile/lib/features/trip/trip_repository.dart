import 'dart:io' show SocketException;

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
id, title, timezone, start_date, end_date, status, revision, updated_at,
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

  /// 合并修改行程项的内容与排期。一次 RPC 同时写入标题、备注、日期、时间、时长。
  Future<TripWriteResult> editTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    required String tripDayId,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? idempotencyKey,
  });

  /// 修改行程项的标题与备注，不碰时间与状态。
  Future<TripWriteResult> updateTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    String? idempotencyKey,
  });

  /// 彻底删除行程项。不可恢复，调用方须先向用户确认。
  Future<int> deleteTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    String? idempotencyKey,
  });

  /// 完成行程。完成后行程及其节点只读。
  Future<TripWriteResult> completeTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  });

  /// 取消行程。取消后仍允许整理节点记录。
  Future<TripWriteResult> cancelTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  });

  /// 删除整份行程及其日期、节点。服务端级联删除子表。
  Future<int> deleteTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  });

  /// 添加一个自由安排节点（`break`）。
  ///
  /// 与 [addPlaceItem] 分成两个方法而非共用一个带可选参数的版本：库端 trigger 要求
  /// `break` 不得带 placeId 与快照、`place_visit` 必须两者都带，合成一个方法就得在
  /// 运行期校验这组互斥，拆开后由签名本身保证。
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

  /// 添加一个地点节点（`place_visit`）。
  ///
  /// [latitude] 与 [longitude] 必须同时给出或同时省略（库端 trigger 强制）。缺坐标
  /// 的地点仍可加入：高德偶有 POI 无坐标，为此拒绝写入等于因为地图画不出就不让用户
  /// 排这家店。此时该节点不参与路线绘制。
  Future<TripWriteResult> addPlaceItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String placeId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    double? latitude,
    double? longitude,
    String? notes,
    String? idempotencyKey,
  });

  /// 统计某一天已有的节点数，用于推导新节点的 position。
  Future<int> countItemsOnDay(String tripDayId);

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
    this.status = TripStatus.draft,
    this.updatedAt,
  });

  final String id;
  final String title;

  /// 行程时区下的起止自然日。
  final DateTime startDate;
  final DateTime endDate;
  final String timezone;
  final TripStatus status;
  final DateTime? updatedAt;

  /// 行程横跨的天数，含首尾两端。
  int get dayCount => endDate.difference(startDate).inDays + 1;
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
          .select(
            'id, title, timezone, start_date, end_date, status, updated_at',
          )
          .order('updated_at', ascending: false);
      return rows
          .map(
            (row) => TripSummary(
              id: row['id'] as String,
              title: (row['title'] as String?) ?? '未命名行程',
              startDate: DateTime.parse(row['start_date'] as String),
              endDate: DateTime.parse(row['end_date'] as String),
              timezone: (row['timezone'] as String?) ?? 'Asia/Shanghai',
              status: TripMapper.tripStatusFromWire(row['status'] as String?),
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

  /// 合并修改行程项的标题、备注、日期、时间与时段。
  @override
  Future<TripWriteResult> editTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    required String tripDayId,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('edit_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_id': tripItemId,
      'p_title': title,
      'p_notes': notes ?? '',
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

  /// 修改行程项的标题与备注，不碰时间与状态。
  @override
  Future<TripWriteResult> updateTripItem({
    required String tripId,
    required int expectedRevision,
    required String tripItemId,
    required String title,
    String? notes,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('update_trip_item', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
      'p_trip_item_id': tripItemId,
      'p_title': title,
      'p_notes': notes ?? '',
    });
    return TripWriteResult(
      id: (payload['trip_item'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  /// 返回删除后行程项的最新 revision。不返回项本身——它已经不存在了。
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

  @override
  Future<TripWriteResult> completeTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('complete_trip', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
    });
    return TripWriteResult(
      id: (payload['trip'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  @override
  Future<TripWriteResult> cancelTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('cancel_trip', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
    });
    return TripWriteResult(
      id: (payload['trip'] as Map<String, dynamic>)['id'] as String,
      revision: (payload['revision'] as num).toInt(),
    );
  }

  @override
  Future<int> deleteTrip({
    required String tripId,
    required int expectedRevision,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final payload = await _rpc('delete_trip', {
      'p_trip_id': tripId,
      'p_expected_revision': expectedRevision,
      'p_idempotency_key': idempotencyKey ?? generateUuidV4(),
    });
    return (payload['deleted_count'] as num?)?.toInt() ?? 0;
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
            'id, revision, timezone, status, start_date, end_date, '
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

  /// 添加一个地点节点。position 由 [countItemsOnDay] 推导，与 [addBreakItem] 一致。
  ///
  /// 快照在此构造而非由调用方传入：`schema_version` 与 `coordinate_system` 是库端
  /// trigger 校验的固定值（itinerary_schema.sql:243-259），让每个调用方各填一遍
  /// 迟早有一处填错。
  @override
  Future<TripWriteResult> addPlaceItem({
    required String tripId,
    required int expectedRevision,
    required String tripDayId,
    required String placeId,
    required String title,
    required DateTime plannedStartAt,
    required DateTime plannedEndAt,
    required TripStopType timeSlot,
    double? latitude,
    double? longitude,
    String? notes,
    String? idempotencyKey,
  }) async {
    final position = await countItemsOnDay(tripDayId);
    // 坐标成对齐全才写入：库端要求两者同时给出或同时省略，只给其一会被拒。
    final hasCoordinates = latitude != null && longitude != null;
    return addTripItem(
      tripId: tripId,
      expectedRevision: expectedRevision,
      tripDayId: tripDayId,
      title: title,
      plannedStartAt: plannedStartAt,
      plannedEndAt: plannedEndAt,
      timeSlot: timeSlot,
      position: position,
      placeId: placeId,
      placeSnapshot: hasCoordinates
          ? PlaceSnapshot(name: title, latitude: latitude, longitude: longitude)
          : PlaceSnapshot(name: title),
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
      return rows.length;
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
    'P0003' => const TripRepositoryException(
      '行程已完成，无法再修改。',
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
