import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_time_zone.dart';

/// 排期选择结果。
@immutable
class ScheduleSelection {
  const ScheduleSelection({
    required this.day,
    required this.hour,
    required this.minute,
    required this.duration,
  });

  /// 所选的行程日。
  ///
  /// 只能取自行程已有的天：库端要求项归属的 trip_day 必须已存在，且项的开始时刻
  /// 按行程时区折算后必须落在该天（itinerary_schema.sql:232）。
  final TripDayRef day;

  /// 行程时区下的墙上时间，不是设备本地时间。
  final int hour;
  final int minute;
  final Duration duration;

  /// 按开始时刻推导时段。
  ///
  /// 不让用户手选时段：时段与时间点冗余，两处可独立编辑必然产生「18:00 的早餐」
  /// 这类自相矛盾的数据。由时间推导则永远自洽。
  TripStopType get timeSlot => timeSlotForHour(hour);
}

/// 时间点到时段的映射。
///
/// 边界按国内常见用餐时间划分；`flexible` 留给深夜与清晨，避免把凌晨 3 点硬塞进
/// 某个餐段。
TripStopType timeSlotForHour(int hour) {
  if (hour >= 6 && hour < 10) return TripStopType.breakfast;
  if (hour >= 10 && hour < 11) return TripStopType.morning;
  if (hour >= 11 && hour < 14) return TripStopType.lunch;
  if (hour >= 14 && hour < 17) return TripStopType.afternoonTea;
  if (hour >= 17 && hour < 21) return TripStopType.dinner;
  if (hour >= 21 && hour < 24) return TripStopType.lateNight;
  return TripStopType.flexible;
}

/// 时段的中文名，用于向用户说明推导结果。
String timeSlotLabel(TripStopType slot) {
  return switch (slot) {
    TripStopType.breakfast => '早餐',
    TripStopType.morning => '上午',
    TripStopType.lunch => '午餐',
    TripStopType.afternoonTea => '下午茶',
    TripStopType.dinner => '晚餐',
    TripStopType.lateNight => '夜宵',
    TripStopType.flexible => '灵活安排',
  };
}

/// 弹出排期选择表单。用户取消时返回 null。
///
/// 加入行程与改期共用此表单：两者的输入完全相同（哪天、几点、多久），差别只在
/// 初值与文案。分成两套表单必然让「日期只能选行程已有的天」这类约束实现两遍。
Future<ScheduleSelection?> showSchedulePickerSheet(
  BuildContext context, {
  required String placeName,
  required TripSchedulingContext trip,
  ScheduleSelection? initial,
  bool isReschedule = false,
}) {
  return showModalBottomSheet<ScheduleSelection>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SchedulePickerSheet(
      placeName: placeName,
      trip: trip,
      initial: initial,
      isReschedule: isReschedule,
    ),
  );
}

class _SchedulePickerSheet extends StatefulWidget {
  const _SchedulePickerSheet({
    required this.placeName,
    required this.trip,
    this.initial,
    this.isReschedule = false,
  });

  final String placeName;
  final TripSchedulingContext trip;

  /// 改期时的当前排期，作为各控件初值。
  final ScheduleSelection? initial;

  /// 改期模式：影响标题与提交按钮文案。
  final bool isReschedule;

  @override
  State<_SchedulePickerSheet> createState() => _SchedulePickerSheetState();
}

class _SchedulePickerSheetState extends State<_SchedulePickerSheet> {
  /// 可选时长，覆盖一顿快餐到一场长饭局。
  static const List<int> _durationChoices = [30, 60, 90, 120, 180];

  late TripDayRef _day;
  late TimeOfDay _time;
  Duration _duration = const Duration(hours: 1);

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    // 改期时以现有排期为初值；新加入时默认首日 12:00。
    _day = initial?.day ?? widget.trip.days.first;
    _time = initial == null
        ? const TimeOfDay(hour: 12, minute: 0)
        : TimeOfDay(hour: initial.hour, minute: initial.minute);
    _duration = initial?.duration ?? const Duration(hours: 1);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.localDate,
      // 只允许在行程既有的日期区间内选择，且逐日校验：库端要求对应的
      // trip_day 必须已存在，选到不存在的日期会被 trigger 拒绝。
      firstDate: widget.trip.firstDate,
      lastDate: widget.trip.lastDate,
      selectableDayPredicate: (date) => widget.trip.dayOn(date) != null,
      helpText: '选择行程中的哪一天',
    );
    if (picked == null) return;
    final day = widget.trip.dayOn(picked);
    if (day == null) return;
    setState(() => _day = day);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      helpText: '选择到店时间',
    );
    if (picked == null) return;
    setState(() => _time = picked);
  }

  void _submit() {
    Navigator.of(context).pop(
      ScheduleSelection(
        day: _day,
        hour: _time.hour,
        minute: _time.minute,
        duration: _duration,
      ),
    );
  }

  /// 跨时区时给出设备本地时间的对照，无时差则返回 null（不显示冗余信息）。
  String? _deviceTimeHint() {
    final instant = TripTimeZone.toInstant(
      timezone: widget.trip.timezone,
      localDate: _day.localDate,
      hour: _time.hour,
      minute: _time.minute,
    );
    if (!TripTimeZone.differsFromDevice(
      timezone: widget.trip.timezone,
      instant: instant,
    )) {
      return null;
    }

    // 用 epoch 毫秒重建普通 DateTime 取设备本地时间：instant 是 TZDateTime，
    // 其 toLocal() 走时区库而非设备时区（见 TripTimeZone.deviceOffsetAt）。
    final local = DateTime.fromMillisecondsSinceEpoch(
      instant.millisecondsSinceEpoch,
    );
    final difference = TripTimeZone.formatOffsetDifference(
      timezone: widget.trip.timezone,
      instant: instant,
    );
    return '行程地时间比你当前所在地 $difference；'
        '你本地为 ${formatLocalDate(local)} '
        '${formatWallClock(local.hour, local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final slot = timeSlotForHour(_time.hour);
    final endMinutes = _time.hour * 60 + _time.minute + _duration.inMinutes;
    final canPickDate = widget.trip.days.length > 1;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isReschedule ? '调整到店时间' : '安排到店时间',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              widget.placeName,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppTokens.spaceLg),
            _PickerRow(
              icon: Icons.event_outlined,
              label: '日期',
              value: formatLocalDate(_day.localDate),
              // 单日行程无从选择，禁用比给一个只有一个选项的弹窗更诚实。
              onTap: canPickDate ? _pickDate : null,
              hint: canPickDate ? null : '该行程只有一天',
            ),
            const Divider(height: 1),
            _PickerRow(
              icon: Icons.schedule_outlined,
              label: '时间',
              value: formatWallClock(_time.hour, _time.minute),
              onTap: _pickTime,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Text('停留时长', style: theme.textTheme.labelLarge),
            const SizedBox(height: AppTokens.spaceSm),
            Wrap(
              spacing: AppTokens.spaceSm,
              children: _durationChoices.map((minutes) {
                return ChoiceChip(
                  label: Text(formatDuration(Duration(minutes: minutes))),
                  selected: _duration.inMinutes == minutes,
                  onSelected: (_) =>
                      setState(() => _duration = Duration(minutes: minutes)),
                );
              }).toList(),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            // 时段由时间推导，显式告知结果，避免「为什么被归到夜宵」的困惑。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              ),
              child: Text(
                '将排入「${timeSlotLabel(slot)}」时段，'
                '${formatWallClock(_time.hour, _time.minute)}–'
                '${formatWallClock((endMinutes ~/ 60) % 24, endMinutes % 60)}'
                '${endMinutes >= 24 * 60 ? '（次日）' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            // 跨时区行程并列显示设备本地时间：用户订机票、和家人报备时间时用的是
            // 自己所在时区的钟点，只给当地时间会逼他心算时差。
            if (_deviceTimeHint() case final hint?) ...[
              const SizedBox(height: AppTokens.spaceSm),
              Row(
                children: [
                  Icon(Icons.public, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: AppTokens.spaceXs),
                  Expanded(
                    child: Text(
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppTokens.spaceLg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceMd),
                Expanded(
                  child: FilledButton(
                    onPressed: _submit,
                    child: Text(widget.isReschedule ? '保存改期' : '加入行程'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// `2026-09-01（周二）` 形式的日期。
String formatLocalDate(DateTime date) {
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day（周${weekdays[date.weekday - 1]}）';
}

/// 24 小时制的 `HH:mm`。
///
/// 不用 `TimeOfDay.format` 是为了避免依赖设备的 12/24 制设置：行程时间是行程
/// 时区下的墙上时间，需要在任何设备上呈现一致。
String formatWallClock(int hour, int minute) {
  return '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';
}

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    final hintText = hint;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceMd),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppTokens.spaceSm),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                if (hintText != null)
                  Text(
                    hintText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (enabled) const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}
