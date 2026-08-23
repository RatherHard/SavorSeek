import 'package:savorseek/features/places/place_models.dart';

import 'schedule_picker_sheet.dart';
import 'trip_repository.dart';
import 'trip_time_zone.dart';

/// 把地点加入行程的能力。
///
/// 抽成接口是为了让探索页不依赖 [SupabaseTripRepository] 这一具体实现——
/// Widget 测试无法初始化 Supabase，只有依赖可替换才能覆盖排期与写入的分支。
abstract interface class PlaceScheduler {
  /// 读取排期上下文，供 UI 构造时间选择器。返回 null 表示还没有可加入的行程。
  Future<TripSchedulingContext?> loadContext();

  Future<void> add({
    required Place place,
    required TripSchedulingContext trip,
    required ScheduleSelection selection,
  });
}

/// 把一个地点按指定排期加入行程。
///
/// 这是探索页与行程写入之间唯一的耦合点，单独成文件而非塞进 UI：写入涉及
/// revision、position、时区折算三处易错约束，值得独立测试。
class AddPlaceToTrip implements PlaceScheduler {
  const AddPlaceToTrip(this._repository);

  final SupabaseTripRepository _repository;

  @override
  Future<TripSchedulingContext?> loadContext() =>
      _repository.findSchedulingContext();

  @override
  Future<void> add({
    required Place place,
    required TripSchedulingContext trip,
    required ScheduleSelection selection,
  }) async {
    // position 必须避开同一天已有项：(trip_day_id, position) 对非取消项唯一。
    final position = await _repository.countItemsOnDay(selection.day.id);

    final start = resolveInstant(
      localDate: selection.day.localDate,
      timezone: trip.timezone,
      hour: selection.hour,
      minute: selection.minute,
    );

    await _repository.addTripItem(
      tripId: trip.tripId,
      expectedRevision: trip.revision,
      tripDayId: selection.day.id,
      title: place.name,
      plannedStartAt: start,
      plannedEndAt: start.add(selection.duration),
      timeSlot: selection.timeSlot,
      position: position,
      placeId: place.id,
      placeSnapshot: buildSnapshot(place),
    );
  }
}

/// 由地点构造合规的行程项快照。
///
/// 库端 trigger 逐项校验（itinerary_schema.sql:243-259）：`schema_version` 必须
/// 为 1、`name` 非空、经纬度成对出现、给出时 `coordinate_system` 合法。`places`
/// 的坐标恒为 gcj02，与约束及地图底图一致。
PlaceSnapshot buildSnapshot(Place place) {
  return PlaceSnapshot(
    name: place.name,
    latitude: place.latitude,
    longitude: place.longitude,
  );
}

/// 把「行程时区下的墙上时间」换算为真正的时刻。
///
/// 库端要求「按行程时区折算后的日期」必须等于所属 trip_day 的 local_date
/// （itinerary_schema.sql:232）。若直接用设备本地时区构造 DateTime，用户在
/// 非行程时区（例如出差时改了手机时区）操作就会写入相邻一天并被拒。
///
/// 换算委托给 [TripTimeZone]，它基于 IANA 时区数据库，因此有夏令时的目的地也能
/// 算对。此前这里维护一张固定偏移表，会在夏令时切换日错一小时。
DateTime resolveInstant({
  required DateTime localDate,
  required String timezone,
  required int hour,
  int minute = 0,
}) {
  return TripTimeZone.toInstant(
    timezone: timezone,
    localDate: localDate,
    hour: hour,
    minute: minute,
  );
}
