import 'trip_models.dart';
import 'trip_time_zone.dart';

/// PostgREST 行数据到 UI 模型的转换层。
///
/// 独立成文件而非塞进 Repository：转换规则（时区、枚举、派生字段）是本次
/// 对接最易出错的部分，单独暴露才能不依赖网络直接单测。
abstract final class TripMapper {
  /// 由嵌套查询结果构造完整行程。
  ///
  /// 期望形状：`trips` 行内含 `trip_days` 数组，每个 day 内含 `trip_items` 数组。
  static TripPlan planFromRow(Map<String, dynamic> row) {
    // 时区必须先取出：所有行程项时间都按它折算。缺失时退回库端默认值而非设备
    // 时区——后者会让同一条行程在不同设备上显示不同时间。
    final timezone = (row['timezone'] as String?) ?? 'Asia/Shanghai';
    final days = _listOf(row['trip_days'])
        .map((day) => dayFromRow(day, timezone: timezone))
        .toList(growable: false);
    final plan = TripPlan(
      id: row['id'] as String,
      title: (row['title'] as String?) ?? '未命名行程',
      destination: destinationOf(days),
      updatedAt: _parseTimestamp(row['updated_at']),
      timezone: timezone,
      revision: (row['revision'] as num?)?.toInt() ?? 1,
      status: tripStatusFromWire(row['status'] as String?),
      days: days,
    );
    // 地图可用性由数据决定而非另行传入：少于两个可定位节点时没有「路径」可画，
    // 此时标为不可用，UI 据此显示说明而不是一张只有一个点的地图。
    return plan.hasRoute
        ? plan.copyWith(mapState: TripMapState.available)
        : plan;
  }

  static TripDay dayFromRow(
    Map<String, dynamic> row, {
    String timezone = 'Asia/Shanghai',
  }) {
    final date = _parseDate(row['local_date'] as String);
    return TripDay(
      id: row['id'] as String?,
      date: date,
      label: dayLabel(date),
      stops: _listOf(row['trip_items'])
          .map((item) => stopFromRow(item, timezone: timezone))
          .toList(growable: false),
    );
  }

  static TripStop stopFromRow(
    Map<String, dynamic> row, {
    String timezone = 'Asia/Shanghai',
  }) {
    final type = stopTypeFromWire(row['time_slot'] as String?);
    final startAt = _toTripWallClock(
      _parseTimestamp(row['planned_start_at'])!,
      timezone,
    );
    final endAt = _toTripWallClock(
      _parseTimestamp(row['planned_end_at'])!,
      timezone,
    );
    final coordinates = coordinatesFrom(row['place_snapshot']);
    return TripStop(
      id: row['id'] as String,
      title: (row['title'] as String?) ?? '未命名地点',
      subtitle: stopSubtitle(type: type, startAt: startAt, endAt: endAt),
      startAt: startAt,
      endAt: endAt,
      type: type,
      itemType: itemTypeFromWire(row['item_type'] as String?),
      note: _nonEmpty(row['notes'] as String?),
      isLocked: isLockedFrom(row),
      tripDayId: row['trip_day_id'] as String?,
      status: statusFromWire(row['status'] as String?),
      latitude: coordinates?.$1,
      longitude: coordinates?.$2,
    );
  }

  /// 从 `place_snapshot` 取出经纬度，缺失或不合法时返回 null。
  ///
  /// 库端 trigger 已保证「成对出现且在合法范围内」，此处仍逐项校验：快照是
  /// jsonb，历史数据或未来的写入路径都可能绕过校验，一个越界坐标会让地图把
  /// 视野拉到世界另一端。返回 (纬度, 经度)。
  static (double, double)? coordinatesFrom(Object? snapshot) {
    if (snapshot is! Map) return null;
    final latitude = _toDouble(snapshot['latitude']);
    final longitude = _toDouble(snapshot['longitude']);
    if (latitude == null || longitude == null) return null;
    if (latitude.abs() > 90 || longitude.abs() > 180) return null;
    return (latitude, longitude);
  }

  /// jsonb 的数字可能读回 int 或 double，也可能是字符串，故统一归一化。
  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static TripStatus tripStatusFromWire(String? wire) {
    for (final value in TripStatus.values) {
      if (value.wireName == wire) return value;
    }
    return TripStatus.draft;
  }

  static TripItemStatus statusFromWire(String? wire) {
    for (final value in TripItemStatus.values) {
      if (value.wireName == wire) return value;
    }
    return TripItemStatus.planned;
  }

  /// 三个锁定标志按「任一为真」合并（缺失视为 false）。
  static bool isLockedFrom(Map<String, dynamic> row) {
    return (row['is_place_locked'] as bool? ?? false) ||
        (row['is_time_locked'] as bool? ?? false) ||
        (row['is_order_locked'] as bool? ?? false);
  }

  static TripStopType stopTypeFromWire(String? wire) {
    for (final value in TripStopType.values) {
      if (value.wireName == wire) return value;
    }
    // 库端 check 约束保证取值合法；出现未知值说明库先行扩展了枚举，
    // 此时退回 flexible 而不是抛错，避免整张行程因一个新时段无法显示。
    return TripStopType.flexible;
  }

  static TripItemType itemTypeFromWire(String? wire) {
    for (final value in TripItemType.values) {
      if (value.wireName == wire) return value;
    }
    return TripItemType.placeVisit;
  }

  /// `TripPlan.destination` 在库中无对应列，由行程项标题派生。
  ///
  /// 取前两项地点名拼接；无地点项时返回空串，由 UI 决定是否留白。
  static String destinationOf(List<TripDay> days) {
    final titles = days
        .expand((day) => day.stops)
        .where((stop) => stop.itemType == TripItemType.placeVisit)
        .map((stop) => stop.title)
        .toList(growable: false);
    if (titles.isEmpty) return '';
    final shown = titles.take(2).join(' · ');
    return titles.length > 2 ? '$shown 等 ${titles.length} 处' : shown;
  }

  static const List<String> _weekdayNames = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  /// 生成「周六 · 8 月 22 日」形式的日期标签，库中无对应列。
  static String dayLabel(DateTime date) {
    final weekday = _weekdayNames[date.weekday - 1];
    return '$weekday · ${date.month} 月 ${date.day} 日';
  }

  /// 拼装「午餐 · 12:00–13:30」形式的副标题，库中无对应列。
  static String stopSubtitle({
    required TripStopType type,
    required DateTime startAt,
    required DateTime endAt,
  }) {
    return '${slotLabel(type)} · ${_formatTime(startAt)}–${_formatTime(endAt)}';
  }

  static String slotLabel(TripStopType type) {
    return switch (type) {
      TripStopType.breakfast => '早餐',
      TripStopType.morning => '上午',
      TripStopType.lunch => '午餐',
      TripStopType.afternoonTea => '下午茶',
      TripStopType.dinner => '晚餐',
      TripStopType.lateNight => '夜宵',
      TripStopType.flexible => '待定时段',
    };
  }

  /// 把 timestamptz 折算为行程时区下的墙上时间。
  ///
  /// 按行程时区而非设备时区：一条东京行程的 19:00 到店，用户在国内查看时也应显示
  /// 19:00（当地钟面时间），而不是设备时区下的 18:00。数据模型文档第 33 行同样
  /// 要求「必须按 `trips.timezone` 转换，不得按客户端设备时区或 UTC 判断」。
  ///
  /// 时区无法识别时退回设备本地时间：宁可时间显示得不准，也不能让整张行程因一个
  /// 无法识别的时区标识而打不开。
  static DateTime _toTripWallClock(DateTime instant, String timezone) {
    try {
      return TripTimeZone.toWallClock(timezone: timezone, instant: instant);
    } on TripTimeZoneException {
      return instant.isUtc ? instant.toLocal() : instant;
    }
  }

  static DateTime? _parseTimestamp(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.parse(value);
  }

  static DateTime _parseDate(String value) {
    final parts = value.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<Map<String, dynamic>> _listOf(Object? value) {
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList(growable: false);
  }
}
