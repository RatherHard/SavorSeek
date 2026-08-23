import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// 行程时区的换算。
///
/// 用 IANA 时区数据库而非固定偏移表：数据模型文档第 34 行明确要求
/// 「时区必须使用 IANA 标识，不得只保存 `UTC+8` 一类固定偏移」。原因是有夏令时的
/// 目的地（东京没有，但巴黎、纽约、悉尼有）一年中偏移会变，固定偏移会在夏令时
/// 切换日算错一小时——而这类错误只在特定日期出现，极难察觉。
///
/// 加载 `latest_10y` 而非完整数据库：前者覆盖当前前后十年的规则，足够旅行规划
/// 使用，完整库体积大一倍多。
abstract final class TripTimeZone {
  static bool _initialized = false;

  /// 加载时区数据。多次调用无副作用，供 `main()` 与测试各自安全调用。
  static void ensureInitialized() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  /// 时区标识是否可用。
  static bool isSupported(String timezone) {
    ensureInitialized();
    return _lookup(timezone) != null;
  }

  /// 把「行程时区下的墙上时间」换算为绝对时刻（UTC）。
  ///
  /// 库端要求行程项的 `planned_start_at` 按 `trips.timezone` 折算后的日期等于所属
  /// `trip_days.local_date`（itinerary_schema.sql:232），因此绝不能用设备本地时区
  /// 构造——用户在非行程时区操作时会写入相邻一天并被拒。
  ///
  /// 夏令时空档（如巴黎 2026-03-29 02:30 不存在）由 `timezone` 包归一到该时刻之后
  /// 的有效时间，不抛错：让用户选到一个不存在的钟点后失败，不如落到最接近的有效
  /// 时刻并照常写入。
  static DateTime toInstant({
    required String timezone,
    required DateTime localDate,
    required int hour,
    int minute = 0,
  }) {
    final location = _requireLocation(timezone);
    final wall = tz.TZDateTime(
      location,
      localDate.year,
      localDate.month,
      localDate.day,
      hour,
      minute,
    );
    return wall.toUtc();
  }

  /// 把绝对时刻换算为行程时区下的墙上时间。
  ///
  /// 返回的 `DateTime` 的各字段即行程当地的年月日时分，不带时区标记——它表示
  /// 「当地钟面上显示什么」，不应再参与任何时区换算。
  static DateTime toWallClock({
    required String timezone,
    required DateTime instant,
  }) {
    final location = _requireLocation(timezone);
    final local = tz.TZDateTime.from(instant, location);
    return DateTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
    );
  }

  /// 行程时区在某一时刻的 UTC 偏移。用于向用户说明时差。
  static Duration offsetAt({
    required String timezone,
    required DateTime instant,
  }) {
    final location = _requireLocation(timezone);
    return tz.TZDateTime.from(instant, location).timeZoneOffset;
  }

  /// 设备时区与行程时区在某一时刻是否存在时差。
  ///
  /// 按偏移比较而非按时区名：`Asia/Shanghai` 与 `Asia/Macau` 名称不同但恒为同一
  /// 偏移，对用户而言没有时差，不该显示双时间。
  static bool differsFromDevice({
    required String timezone,
    required DateTime instant,
  }) {
    final tripOffset = offsetAt(timezone: timezone, instant: instant);
    return tripOffset != instant.toLocal().timeZoneOffset;
  }

  /// 时差的可读表述，如 `+1 小时`、`-3 小时`、`+1 小时 30 分`。
  static String formatOffsetDifference({
    required String timezone,
    required DateTime instant,
  }) {
    final delta =
        offsetAt(timezone: timezone, instant: instant) -
        instant.toLocal().timeZoneOffset;
    if (delta == Duration.zero) return '无时差';

    final sign = delta.isNegative ? '-' : '+';
    final absolute = delta.abs();
    final hours = absolute.inHours;
    final minutes = absolute.inMinutes % 60;
    if (minutes == 0) return '$sign$hours 小时';
    return '$sign$hours 小时 $minutes 分';
  }

  static tz.Location _requireLocation(String timezone) {
    final location = _lookup(timezone);
    if (location == null) {
      throw TripTimeZoneException(timezone);
    }
    return location;
  }

  /// 同义时区名。
  ///
  /// `latest_10y` 数据集只收录 `Etc/UTC` 而没有裸 `UTC`，但 `trips.timezone` 完全
  /// 可能存 `UTC`（PostgreSQL 的 `pg_timezone_names` 收录该名称，库端校验会通过）。
  /// 不做映射会让这类行程在客户端直接报「无法识别时区」。
  static const Map<String, String> _aliases = {
    'UTC': 'Etc/UTC',
    'GMT': 'Etc/GMT',
    'Etc/GMT+0': 'Etc/GMT',
    'Etc/UCT': 'Etc/UTC',
    'Universal': 'Etc/UTC',
    'Zulu': 'Etc/UTC',
  };

  static tz.Location? _lookup(String timezone) {
    ensureInitialized();
    final name = _aliases[timezone] ?? timezone;
    try {
      return tz.getLocation(name);
    } on tz.LocationNotFoundException {
      return null;
    }
  }
}

/// 时区标识无法识别。
///
/// 单独成类而非复用仓库异常：这是数据问题（库里存了本地时区库不认识的标识），
/// 与网络、权限、冲突等运行时失败性质不同，调用方可能需要区别处理。
class TripTimeZoneException implements Exception {
  const TripTimeZoneException(this.timezone);

  final String timezone;

  @override
  String toString() => '无法识别行程时区 $timezone，请联系支持。';
}
