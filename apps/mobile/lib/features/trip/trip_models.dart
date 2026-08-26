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

/// 行程生命周期状态，对应 `trips.status` 的 check 约束。
enum TripStatus {
  draft('draft'),
  confirmed('confirmed'),
  inProgress('in_progress'),
  completed('completed'),
  cancelled('cancelled');

  const TripStatus(this.wireName);

  final String wireName;

  bool get isTerminal => this == completed || this == cancelled;
}

/// 行程项状态，对应 `trip_items.status` 的 check 约束。
enum TripItemStatus {
  planned('planned'),
  completed('completed'),
  skipped('skipped');

  const TripItemStatus(this.wireName);

  final String wireName;

  /// 终态项不可再改期或改状态（库端 trigger 亦如此约束）。
  bool get isTerminal => this != TripItemStatus.planned;
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
    this.tripDayId,
    this.status = TripItemStatus.planned,
    this.latitude,
    this.longitude,
  }) : assert((latitude == null) == (longitude == null), '经纬度必须同时提供或同时省略');

  final String id;
  final String title;
  final String subtitle;

  /// 行程时区下的墙上时间，即「当地钟面上显示什么」。
  ///
  /// 不是设备本地时间：跨时区行程若按设备时区展示，用户在国内看东京行程会看到
  /// 18:00，而当地实际是 19:00。改期时也以此为初值。
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

  /// 所属行程日的 id，改期时作为「当前所在那天」的标识。
  ///
  /// 可空是因为演示数据与纯 UI 测试构造的 stop 没有真实归属；此时改期入口禁用。
  final String? tripDayId;

  /// 项的状态。终态项不可改期（库端亦会拒绝）。
  final TripItemStatus status;

  /// 地点坐标，取自 `trip_items.place_snapshot`。
  ///
  /// 坐标系恒为 gcj02（与高德底图一致，无需转换）。休息项与快照缺经纬度的地点项
  /// 为空，此时该节点不参与路线绘制。
  final double? latitude;
  final double? longitude;

  /// 是否可在地图上定位。
  bool get hasCoordinates => latitude != null && longitude != null;

  /// 是否可改期。
  ///
  /// 终态项改期没有意义且会让历史失真；缺少 tripDayId 时无法构造写入请求。
  bool get canReschedule =>
      tripDayId != null && status == TripItemStatus.planned;

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
    String? tripDayId,
    TripItemStatus? status,
    double? latitude,
    double? longitude,
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
      tripDayId: tripDayId ?? this.tripDayId,
      status: status ?? this.status,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
    );
  }
}

@immutable
class TripDay {
  TripDay({
    required this.date,
    required this.label,
    required List<TripStop> stops,
    this.id,
  }) : stops = List.unmodifiable(stops);

  /// `trip_days.id`。改期时作为目标日标识。
  ///
  /// 可空是因为演示数据与纯 UI 测试构造的 day 没有真实归属。
  final String? id;

  /// 行程时区下的自然日。
  final DateTime date;
  final String label;
  final List<TripStop> stops;

  TripDay copyWith({
    String? id,
    DateTime? date,
    String? label,
    List<TripStop>? stops,
  }) {
    return TripDay(
      id: id ?? this.id,
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
    this.timezone = 'Asia/Shanghai',
    this.revision = 1,
    this.status = TripStatus.draft,
  }) : days = List.unmodifiable(days);

  final String id;
  final String title;
  final String destination;
  final List<TripDay> days;
  final TripMapState mapState;
  final DateTime? updatedAt;

  /// 行程时区（IANA 标识）。所有行程项时间均按此时区呈现。
  final String timezone;

  /// 乐观并发控制的修订号，改期时作为 expected_revision。
  final int revision;

  /// 行程生命周期状态。
  final TripStatus status;

  int get stopCount => days.fold(0, (count, day) => count + day.stops.length);

  /// 按时间顺序排列的、可在地图上定位的节点。
  ///
  /// 所有计划内节点都参与路线；节点级取消已由数据库状态约束移除。
  List<TripStop> get routeStops {
    return [
      for (final day in days)
        for (final stop in day.stops)
          if (stop.hasCoordinates) stop,
    ];
  }

  /// 地图能否呈现这份行程。一个可定位节点就够。
  ///
  /// 不要求两个：只有一个地点时地图仍有信息量（它在城市的哪一侧、离住处多远），
  /// 拿占位图盖掉它等于把已有的信息藏起来。能否画连线是另一回事，见
  /// [hasRouteLine]。
  bool get hasRoute => routeStops.isNotEmpty;

  /// 能否画出连线。至少要两个可定位节点才谈得上「路径」。
  ///
  /// 与 [hasRoute] 分开：地图该不该出现、线该不该画，是两个不同的判断。
  bool get hasRouteLine => routeStops.length >= 2;

  TripPlan copyWith({
    String? id,
    String? title,
    String? destination,
    List<TripDay>? days,
    TripMapState? mapState,
    DateTime? updatedAt,
    String? timezone,
    int? revision,
    TripStatus? status,
  }) {
    return TripPlan(
      id: id ?? this.id,
      title: title ?? this.title,
      destination: destination ?? this.destination,
      days: days ?? this.days,
      mapState: mapState ?? this.mapState,
      updatedAt: updatedAt ?? this.updatedAt,
      timezone: timezone ?? this.timezone,
      revision: revision ?? this.revision,
      status: status ?? this.status,
    );
  }

  bool get isReadOnly => status == TripStatus.completed;
}
