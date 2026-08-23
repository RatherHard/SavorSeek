import 'trip_models.dart';

/// PostgREST 行数据到 UI 模型的转换层。
///
/// 独立成文件而非塞进 Repository：转换规则（时区、枚举、派生字段）是本次
/// 对接最易出错的部分，单独暴露才能不依赖网络直接单测。
abstract final class TripMapper {
  /// 由嵌套查询结果构造完整行程。
  ///
  /// 期望形状：`trips` 行内含 `trip_days` 数组，每个 day 内含 `trip_items` 数组。
  static TripPlan planFromRow(Map<String, dynamic> row) {
    final days = _listOf(row['trip_days'])
        .map(dayFromRow)
        .toList(growable: false);
    return TripPlan(
      id: row['id'] as String,
      title: (row['title'] as String?) ?? '未命名行程',
      destination: destinationOf(days),
      updatedAt: _parseTimestamp(row['updated_at']),
      days: days,
    );
  }

  static TripDay dayFromRow(Map<String, dynamic> row) {
    final date = _parseDate(row['local_date'] as String);
    return TripDay(
      date: date,
      label: dayLabel(date),
      stops: _listOf(row['trip_items'])
          .map(stopFromRow)
          .toList(growable: false),
    );
  }

  static TripStop stopFromRow(Map<String, dynamic> row) {
    final type = stopTypeFromWire(row['time_slot'] as String?);
    final startAt = _localize(_parseTimestamp(row['planned_start_at'])!);
    final endAt = _localize(_parseTimestamp(row['planned_end_at'])!);
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
    );
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

  /// 把 timestamptz 转为设备本地时间。
  ///
  /// PostgREST 返回带偏移的字符串，`DateTime.parse` 会保留 UTC 标记；不转换
  /// 会让 UI 直接显示 UTC 时刻（如 04:30 而非 12:30）。行程自身的 `timezone`
  /// 列目前未参与展示——跨时区行程需按该列格式化，属后续待办。
  static DateTime _localize(DateTime value) =>
      value.isUtc ? value.toLocal() : value;

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
