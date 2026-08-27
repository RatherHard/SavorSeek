import 'package:flutter/material.dart';

import 'trip_wheel_picker_sheet.dart';

const int _tripTimePickerMaxHour = 23;
const int _tripTimePickerMaxMinute = 59;

Future<TimeOfDay?> showTripTimePicker(
  BuildContext context, {
  required TimeOfDay initialTime,
  required String title,
}) {
  final initial = TimeOfDay(
    hour: initialTime.hour.clamp(0, _tripTimePickerMaxHour),
    minute: initialTime.minute.clamp(0, _tripTimePickerMaxMinute),
  );
  return showTripWheelPickerSheet<TimeOfDay>(
    context,
    title: title,
    initialValue: initial,
    pickerBuilder: (context, onChanged) =>
        _TripTimePicker(initialTime: initial, onChanged: onChanged),
  );
}

class _TripTimePicker extends StatefulWidget {
  const _TripTimePicker({required this.initialTime, required this.onChanged});

  final TimeOfDay initialTime;
  final ValueChanged<TimeOfDay> onChanged;

  @override
  State<_TripTimePicker> createState() => _TripTimePickerState();
}

class _TripTimePickerState extends State<_TripTimePicker> {
  late int _hour = widget.initialTime.hour;
  late int _minute = widget.initialTime.minute;

  void _emit() {
    widget.onChanged(TimeOfDay(hour: _hour, minute: _minute));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: tripWheelPickerHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TripWheelNumberColumn(
            values: List.generate(_tripTimePickerMaxHour + 1, (index) => index),
            initialIndex: _hour,
            labelBuilder: (value) => value.toString().padLeft(2, '0'),
            onSelectedItemChanged: (value) {
              setState(() => _hour = value);
              _emit();
            },
          ),
          Text(':', style: Theme.of(context).textTheme.titleMedium),
          TripWheelNumberColumn(
            values: List.generate(
              _tripTimePickerMaxMinute + 1,
              (index) => index,
            ),
            initialIndex: _minute,
            labelBuilder: (value) => value.toString().padLeft(2, '0'),
            onSelectedItemChanged: (value) {
              setState(() => _minute = value);
              _emit();
            },
          ),
        ],
      ),
    );
  }
}
