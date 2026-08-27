import 'package:flutter/material.dart';

import 'trip_time_zone.dart';
import 'trip_wheel_picker_sheet.dart';

const Duration defaultTripStopDuration = Duration(hours: 1);
const Duration minimumTripStopDuration = Duration(minutes: 5);
const Duration maximumTripStopDuration = Duration(hours: 12);
const int tripStopDurationMinuteInterval = 5;

Future<Duration?> showTripDurationPicker(
  BuildContext context, {
  required Duration initialDuration,
}) {
  final clamped = clampTripStopDuration(initialDuration);
  return showTripWheelPickerSheet<Duration>(
    context,
    title: '选择停留时长',
    initialValue: clamped,
    helperText: '最短 5 分钟，最长 12 小时',
    isValueValid: _isTripStopDurationValid,
    pickerBuilder: (context, onChanged) =>
        _TripDurationPicker(initialDuration: clamped, onChanged: onChanged),
  );
}

bool _isTripStopDurationValid(Duration value) {
  return value >= minimumTripStopDuration && value <= maximumTripStopDuration;
}

Duration clampTripStopDuration(Duration value) {
  if (value < minimumTripStopDuration) return minimumTripStopDuration;
  if (value > maximumTripStopDuration) return maximumTripStopDuration;
  final minutes = value.inMinutes;
  final rounded =
      (minutes / tripStopDurationMinuteInterval).round() *
      tripStopDurationMinuteInterval;
  final bounded = rounded.clamp(
    minimumTripStopDuration.inMinutes,
    maximumTripStopDuration.inMinutes,
  );
  return Duration(minutes: bounded);
}

String formatTripStopDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest 分钟';
  if (rest == 0) return '$hours 小时';
  return '$hours 小时 $rest 分';
}

String formatScheduleRange({
  required DateTime localDate,
  required int hour,
  required int minute,
  required Duration duration,
  required String timezone,
}) {
  final startInstant = TripTimeZone.toInstant(
    timezone: timezone,
    localDate: localDate,
    hour: hour,
    minute: minute,
  );
  final start = TripTimeZone.toWallClock(
    timezone: timezone,
    instant: startInstant,
  );
  final end = TripTimeZone.toWallClock(
    timezone: timezone,
    instant: startInstant.add(duration),
  );
  final nextDay =
      start.year != end.year ||
      start.month != end.month ||
      start.day != end.day;
  final endText =
      '${_formatWallClock(end.hour, end.minute)}'
      '${nextDay ? '（次日）' : ''}';
  return '${_formatWallClock(start.hour, start.minute)}–$endText';
}

class _TripDurationPicker extends StatefulWidget {
  const _TripDurationPicker({
    required this.initialDuration,
    required this.onChanged,
  });

  final Duration initialDuration;
  final ValueChanged<Duration> onChanged;

  @override
  State<_TripDurationPicker> createState() => _TripDurationPickerState();
}

class _TripDurationPickerState extends State<_TripDurationPicker> {
  late int _hours = widget.initialDuration.inHours;
  late int _minutes = widget.initialDuration.inMinutes % 60;

  void _emit() {
    widget.onChanged(Duration(hours: _hours, minutes: _minutes));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: tripWheelPickerHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TripWheelNumberColumn(
            values: List.generate(13, (index) => index),
            initialIndex: _hours,
            labelBuilder: (value) => '$value',
            onSelectedItemChanged: (value) {
              setState(() => _hours = value);
              _emit();
            },
          ),
          Text('小时', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: 12),
          TripWheelNumberColumn(
            values: List.generate(12, (index) => index * 5),
            initialIndex: _minutes ~/ tripStopDurationMinuteInterval,
            labelBuilder: (value) => '$value',
            onSelectedItemChanged: (value) {
              setState(() => _minutes = value);
              _emit();
            },
          ),
          Text('分钟', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

String _formatWallClock(int hour, int minute) {
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
