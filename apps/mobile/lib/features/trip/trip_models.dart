import 'package:flutter/foundation.dart';

/// 行程项所属时段，取值与数据库 `trip_items.time_slot` 的 check 约束一一对应。
///
/// 刻意与库对齐而非另立一套 UI 枚举：任何有损映射都会让读回的行程在写回时
/// 丢失原始时段，双向转换必须是恒等的。
enum TripStopType {
  breakfast('breakfast'),
  morning('morning'),
  lunch('lunch'),
  afternoonTea('afternoon_tea'),
  dinner('dinner'),
  lateNight('late_night'),
  flexible('flexible');

  const TripStopType(this.wireName);

  /// 数据库中的字面值。
  final String wireName;
}

/// 行程项类型，对应 `trip_items.item_type`。休息项用 [TripItemType.break_] 表达。
enum TripItemType {
  placeVisit('place_visit'),
  break_('break');

  const TripItemType(this.wireName);

  final String wireName;
}

enum TripMapState { available, unavailable }

@immutable
class TripStop {
  const TripStop({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.startAt,
    required this.endAt,
    required this.type,
    this.itemType = TripItemType.placeVisit,
    this.note,
    this.isLocked = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final DateTime startAt;
  final DateTime endAt;
  final TripStopType type;
  final TripItemType itemType;
  final String? note;

  /// 是否对用户呈现为「已锁定」。
  ///
  /// 库中拆为地点/时间/顺序三个标志，此处按任一为真合并：锁图标表达
  /// 「此项受保护」，与用户直觉一致。写入侧仍按具体操作分别设置。
  final bool isLocked;

  TripStop copyWith({
    String? id,
    String? title,
    String? subtitle,
    DateTime? startAt,
    DateTime? endAt,
    TripStopType? type,
    TripItemType? itemType,
    String? note,
    bool? isLocked,
  }) {
    return TripStop(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      type: type ?? this.type,
      itemType: itemType ?? this.itemType,
      note: note ?? this.note,
      isLocked: isLocked ?? this.isLocked,
    );
  }
}

@immutable
class TripDay {
  TripDay({
    required this.date,
    required this.label,
    required List<TripStop> stops,
  }) : stops = List.unmodifiable(stops);

  final DateTime date;
  final String label;
  final List<TripStop> stops;

  TripDay copyWith({DateTime? date, String? label, List<TripStop>? stops}) {
    return TripDay(
      date: date ?? this.date,
      label: label ?? this.label,
      stops: stops ?? this.stops,
    );
  }
}

@immutable
class TripPlan {
  TripPlan({
    required this.id,
    required this.title,
    required this.destination,
    required List<TripDay> days,
    this.mapState = TripMapState.unavailable,
    this.updatedAt,
  }) : days = List.unmodifiable(days);

  final String id;
  final String title;
  final String destination;
  final List<TripDay> days;
  final TripMapState mapState;
  final DateTime? updatedAt;

  int get stopCount => days.fold(0, (count, day) => count + day.stops.length);

  TripPlan copyWith({
    String? id,
    String? title,
    String? destination,
    List<TripDay>? days,
    TripMapState? mapState,
    DateTime? updatedAt,
  }) {
    return TripPlan(
      id: id ?? this.id,
      title: title ?? this.title,
      destination: destination ?? this.destination,
      days: days ?? this.days,
      mapState: mapState ?? this.mapState,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
