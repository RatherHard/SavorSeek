import 'package:savorseek/features/places/place_models.dart';

import 'trip_models.dart';
import 'trip_repository.dart';

/// 把一个地点加入用户当前行程。
///
/// 这是探索页与行程写入之间唯一的耦合点，单独成文件而非塞进 UI：写入涉及
/// revision、position、时区折算三处易错约束，值得独立测试。
class AddPlaceToTrip {
  const AddPlaceToTrip(this._repository);

  final SupabaseTripRepository _repository;

  /// 默认排入的时段与时长。
  ///
  /// 暂固定为午餐档：本迭代不做时间选择 UI，先让闭环可用。Agent 编排接入后由
  /// 排程逻辑决定，届时这两个常量应移除而非调大。
  static const int _defaultStartHour = 12;
  static const Duration _defaultDuration = Duration(hours: 1);

  Future<void> call(Place place) async {
    final target = await _repository.findLatestTripTarget();
    if (target == null) {
      throw const TripRepositoryException('还没有可加入的行程，请先在行程页创建一个。');
    }

    // position 必须避开同一天已有项：(trip_day_id, position) 对非取消项唯一。
    final position = await _repository.countItemsOnDay(target.tripDayId);

    final start = resolveStartInstant(
      localDate: target.localDate,
      timezone: target.timezone,
      hour: _defaultStartHour,
    );

    await _repository.addTripItem(
      tripId: target.tripId,
      expectedRevision: target.revision,
      tripDayId: target.tripDayId,
      title: place.name,
      plannedStartAt: start,
      plannedEndAt: start.add(_defaultDuration),
      timeSlot: TripStopType.lunch,
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

/// 计算行程项的开始时刻。
///
/// 库端要求「按行程时区折算后的日期」必须等于所属 trip_day 的 local_date
/// （itinerary_schema.sql:232）。若直接用设备本地时区构造 DateTime，用户在
/// 非行程时区（例如出差时改了手机时区）操作就会写入相邻一天并被拒。
///
/// 只支持固定偏移的时区。Dart 核心库不含 IANA 时区数据库，而本项目当前所有行程
/// 的时区都是 `Asia/Shanghai`（`trips.timezone` 的默认值）。遇到未知时区时抛错
/// 而非静默按 UTC 处理——后者会写出差一天的数据，且难以察觉。
DateTime resolveStartInstant({
  required DateTime localDate,
  required String timezone,
  required int hour,
}) {
  final offset = _fixedOffsets[timezone];
  if (offset == null) {
    throw TripRepositoryException('暂不支持时区 $timezone 的行程排期。');
  }
  // 先按 UTC 构造「墙上时间」，再减去偏移得到真正的时刻。
  return DateTime.utc(
    localDate.year,
    localDate.month,
    localDate.day,
    hour,
  ).subtract(offset);
}

/// 已知的固定偏移时区。中国全境无夏令时，偏移恒为 +8。
const Map<String, Duration> _fixedOffsets = {
  'Asia/Shanghai': Duration(hours: 8),
  'Asia/Hong_Kong': Duration(hours: 8),
  'Asia/Macau': Duration(hours: 8),
  'Asia/Taipei': Duration(hours: 8),
  'UTC': Duration.zero,
};
