import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/trip_duration_picker.dart';
import 'package:savorseek/features/trip/trip_time_picker.dart';
import 'package:savorseek/features/trip/trip_wheel_picker_sheet.dart';

Widget _wrap(Future<void> Function(BuildContext context) onPressed) =>
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onPressed(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('时间卷帘以数字列和清晰冒号返回选择值', (tester) async {
    TimeOfDay? selected;
    await tester.pumpWidget(
      _wrap((context) async {
        selected = await showTripTimePicker(
          context,
          initialTime: const TimeOfDay(hour: 12, minute: 0),
          title: '选择开始时间',
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(TripWheelNumberColumn), findsNWidgets(2));
    expect(find.text(':'), findsOneWidget);
    expect(find.byType(ShaderMask), findsNWidgets(2));

    final minutePicker = tester.widget<CupertinoPicker>(
      find.byType(CupertinoPicker).last,
    );
    minutePicker.onSelectedItemChanged!(35);
    final hourPicker = tester.widget<CupertinoPicker>(
      find.byType(CupertinoPicker).first,
    );
    hourPicker.onSelectedItemChanged!(19);
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(selected, const TimeOfDay(hour: 19, minute: 35));
  });

  testWidgets('取消时间卷帘后不返回新值', (tester) async {
    TimeOfDay? selected;
    await tester.pumpWidget(
      _wrap((context) async {
        selected = await showTripTimePicker(
          context,
          initialTime: const TimeOfDay(hour: 12, minute: 0),
          title: '选择开始时间',
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(selected, isNull);
  });

  testWidgets('停留时长使用中文单位且不显示英文单位', (tester) async {
    Duration? selected;
    await tester.pumpWidget(
      _wrap((context) async {
        selected = await showTripDurationPicker(
          context,
          initialDuration: const Duration(hours: 1),
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('小时'), findsOneWidget);
    expect(find.text('分钟'), findsOneWidget);
    expect(find.textContaining('hours'), findsNothing);
    expect(find.textContaining('min.'), findsNothing);
    expect(find.byType(TripWheelNumberColumn), findsNWidgets(2));
    expect(find.byType(ShaderMask), findsNWidgets(2));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets('停留时长超出范围时禁止确认', (tester) async {
    await tester.pumpWidget(
      _wrap((context) async {
        await showTripDurationPicker(
          context,
          initialDuration: const Duration(hours: 1),
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final pickers = tester
        .widgetList<CupertinoPicker>(find.byType(CupertinoPicker))
        .toList();

    pickers.first.onSelectedItemChanged!(12);
    pickers.last.onSelectedItemChanged!(1);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNull,
    );

    pickers.last.onSelectedItemChanged!(0);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('共享卷帘确认时返回当前值且窗体保持紧凑', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _wrap((context) async {
        selected = await showTripWheelPickerSheet<String>(
          context,
          title: '选择值',
          initialValue: '初始值',
          pickerBuilder: (context, onChanged) =>
              const SizedBox(height: 100, child: Text('picker')),
          isValueValid: (value) => value.isNotEmpty,
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final sheet = tester.getSize(find.byType(BottomSheet));
    expect(sheet.height, lessThan(tester.view.physicalSize.height));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(selected, '初始值');
  });
}
