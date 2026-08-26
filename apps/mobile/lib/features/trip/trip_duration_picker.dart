import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'trip_time_zone.dart';

const Duration defaultTripStopDuration = Duration(hours: 1);
const Duration minimumTripStopDuration = Duration(minutes: 5);
const Duration maximumTripStopDuration = Duration(hours: 12);
const int tripStopDurationMinuteInterval = 5;

Future<Duration?> showTripDurationPicker(
  BuildContext context, {
  required Duration initialDuration,
}) {
  final clamped = clampTripStopDuration(initialDuration);
  return showModalBottomSheet<Duration>(
    context: context,
    builder: (context) => _TripDurationPicker(initialDuration: clamped),
  );
}

Duration clampTripStopDuration(Duration value) {
  if (value < minimumTripStopDuration) return minimumTripStopDuration;
  if (value > maximumTripStopDuration) return maximumTripStopDuration;
  final minutes = value.inMinutes;
  final rounded =
      (minutes / tripStopDurationMinuteInterval).round() *
      tripStopDurationMinuteInterval;
  return Duration(minutes: rounded);
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
  const _TripDurationPicker({required this.initialDuration});

  final Duration initialDuration;

  @override
  State<_TripDurationPicker> createState() => _TripDurationPickerState();
}

class _TripDurationPickerState extends State<_TripDurationPicker> {
  late Duration _duration = widget.initialDuration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('选择停留时长', style: theme.textTheme.titleMedium),
            SizedBox(
              height: 180,
              child: CupertinoTimerPicker(
                mode: CupertinoTimerPickerMode.hm,
                initialTimerDuration: _duration,
                minuteInterval: tripStopDurationMinuteInterval,
                onTimerDurationChanged: (value) {
                  setState(() => _duration = value);
                },
              ),
            ),
            Text(
              '最短 5 分钟，最长 12 小时',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _duration < minimumTripStopDuration
                        ? null
                        : () => Navigator.of(context).pop(_duration),
                    child: const Text('确定'),
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

String _formatWallClock(int hour, int minute) {
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
