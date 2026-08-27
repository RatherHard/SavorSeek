import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'trip_wheel_picker_sheet.dart';

const int _tripTimePickerAnchorYear = 2020;
const int _tripTimePickerAnchorMonth = 1;
const int _tripTimePickerAnchorDay = 1;

Future<TimeOfDay?> showTripTimePicker(
  BuildContext context, {
  required TimeOfDay initialTime,
  required String title,
}) {
  final initialDateTime = DateTime(
    _tripTimePickerAnchorYear,
    _tripTimePickerAnchorMonth,
    _tripTimePickerAnchorDay,
    initialTime.hour,
    initialTime.minute,
  );
  return showTripWheelPickerSheet<TimeOfDay>(
    context,
    title: title,
    initialValue: initialTime,
    pickerBuilder: (context, onChanged) => CupertinoDatePicker(
      backgroundColor: Colors.transparent,
      mode: CupertinoDatePickerMode.time,
      initialDateTime: initialDateTime,
      use24hFormat: true,
      minuteInterval: 1,
      onDateTimeChanged: (value) =>
          onChanged(TimeOfDay(hour: value.hour, minute: value.minute)),
    ),
  );
}
