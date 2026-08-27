import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/trip_duration_picker.dart';
import 'package:savorseek/features/trip/trip_time_picker.dart';
import 'package:savorseek/features/trip/trip_wheel_picker_sheet.dart';

void main() {
  testWidgets('时间卷帘使用 24 小时制并可返回选择值', (tester) async {
    TimeOfDay? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                selected = await showTripTimePicker(
                  context,
                  initialTime: const TimeOfDay(hour: 12, minute: 0),
                  title: '选择开始时间',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final picker = tester.widget<CupertinoDatePicker>(
      find.byType(CupertinoDatePicker),
    );
    expect(picker.mode, CupertinoDatePickerMode.time);
    expect(picker.use24hFormat, isTrue);
    expect(picker.minuteInterval, 1);
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    for (final filter in tester.widgetList<BackdropFilter>(
      find.byType(BackdropFilter),
    )) {
      final parent = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byWidget(filter),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(parent.ignoring, isTrue);
    }

    picker.onDateTimeChanged(DateTime(2020, 1, 1, 19, 35));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(selected, const TimeOfDay(hour: 19, minute: 35));
  });

  testWidgets('取消时间卷帘后不返回新值', (tester) async {
    TimeOfDay? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                selected = await showTripTimePicker(
                  context,
                  initialTime: const TimeOfDay(hour: 12, minute: 0),
                  title: '选择开始时间',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(selected, isNull);
  });

  testWidgets('停留时长卷帘复用上下边缘效果', (tester) async {
    Duration? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                selected = await showTripDurationPicker(
                  context,
                  initialDuration: const Duration(hours: 1),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoTimerPicker), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    for (final filter in tester.widgetList<BackdropFilter>(
      find.byType(BackdropFilter),
    )) {
      final parent = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byWidget(filter),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(parent.ignoring, isTrue);
    }
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets('停留时长超出范围时禁止确认', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTripDurationPicker(
                context,
                initialDuration: const Duration(hours: 1),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final picker = tester.widget<CupertinoTimerPicker>(
      find.byType(CupertinoTimerPicker),
    );

    picker.onTimerDurationChanged(const Duration(hours: 13));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNull,
    );

    picker.onTimerDurationChanged(const Duration(hours: 12));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('共享卷帘确认时返回当前值', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                selected = await showTripWheelPickerSheet<String>(
                  context,
                  title: '选择值',
                  initialValue: '初始值',
                  pickerBuilder: (context, onChanged) =>
                      const SizedBox(height: 100, child: Text('picker')),
                  isValueValid: (value) => value.isNotEmpty,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(selected, '初始值');
  });
}
