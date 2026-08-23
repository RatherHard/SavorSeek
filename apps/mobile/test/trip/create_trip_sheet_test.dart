import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/trip/create_trip_sheet.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

/// 打开表单并把结果记下来。
Widget wrap(void Function(CreateTripDraft?) onResult) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => onResult(await showCreateTripSheet(context)),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('showCreateTripSheet', () {
    testWidgets('填写标题后提交，回传去空格的草稿', (tester) async {
      CreateTripDraft? draft;
      await tester.pumpWidget(wrap((value) => draft = value));
      await openSheet(tester);

      await tester.enterText(find.byType(TextFormField).first, '  大连三日寻味  ');
      await tester.tap(find.text('创建行程'));
      await tester.pumpAndSettle();

      expect(draft, isNotNull);
      expect(draft!.title, '大连三日寻味');
      // 默认人数 2，未填预算时为 null。
      expect(draft!.partySize, 2);
      expect(draft!.budgetLimitMinor, isNull);
    });

    testWidgets('标题为空白时拦在本地，不回传草稿', (tester) async {
      CreateTripDraft? draft;
      var resultCount = 0;
      await tester.pumpWidget(
        wrap((value) {
          draft = value;
          resultCount++;
        }),
      );
      await openSheet(tester);

      await tester.enterText(find.byType(TextFormField).first, '   ');
      await tester.tap(find.text('创建行程'));
      await tester.pumpAndSettle();

      // 表单未关闭，也未回传结果。
      expect(find.text('请填写行程标题'), findsOneWidget);
      expect(resultCount, 0);
      expect(draft, isNull);
    });

    testWidgets('预算按元转分，四舍五入', (tester) async {
      CreateTripDraft? draft;
      await tester.pumpWidget(wrap((value) => draft = value));
      await openSheet(tester);

      await tester.enterText(find.byType(TextFormField).first, '测试行程');
      await tester.enterText(find.byType(TextFormField).last, '99.99');
      await tester.tap(find.text('创建行程'));
      await tester.pumpAndSettle();

      // 截断会得到 9998，必须是 9999。
      expect(draft!.budgetLimitMinor, 9999);
    });

    testWidgets('非数字预算被拦下', (tester) async {
      await tester.pumpWidget(wrap((_) {}));
      await openSheet(tester);

      await tester.enterText(find.byType(TextFormField).first, '测试行程');
      await tester.enterText(find.byType(TextFormField).last, '八百');
      await tester.tap(find.text('创建行程'));
      await tester.pumpAndSettle();

      expect(find.text('请填写数字金额'), findsOneWidget);
    });

    testWidgets('人数受库端 1..50 约束限制', (tester) async {
      await tester.pumpWidget(wrap((_) {}));
      await openSheet(tester);

      // 默认 2，减一次后应停在 1（下界）。
      await tester.tap(find.byTooltip('减少人数'));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);

      // byTooltip 命中的是 Tooltip 而非 IconButton，需按类型再找一层。
      final decrement = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.remove_circle_outline),
          matching: find.byType(IconButton),
        ),
      );
      expect(decrement.onPressed, isNull);
    });

    testWidgets('取消返回 null', (tester) async {
      CreateTripDraft? draft;
      var resultCount = 0;
      await tester.pumpWidget(
        wrap((value) {
          draft = value;
          resultCount++;
        }),
      );
      await openSheet(tester);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(resultCount, 1);
      expect(draft, isNull);
    });
  });

  group('formatTripRange', () {
    test('同一天标注当天往返', () {
      expect(
        formatTripRange(DateTime(2026, 9, 1), DateTime(2026, 9, 1)),
        '2026-09-01（当天往返）',
      );
    });

    test('跨天显示天数，含首尾两天', () {
      expect(
        formatTripRange(DateTime(2026, 9, 1), DateTime(2026, 9, 3)),
        '2026-09-01 起 3 天',
      );
    });
  });

  group('CreateTripKeys', () {
    test('同一实例内每天的键固定不变，供重试复用', () {
      final keys = CreateTripKeys();

      expect(keys.dayKeyAt(0), keys.dayKeyAt(0));
      expect(keys.trip, keys.trip);
      // 不同天必须是不同的键，否则第二天会命中第一天的幂等结果。
      expect(keys.dayKeyAt(0), isNot(keys.dayKeyAt(1)));
      expect(keys.trip, isNot(keys.dayKeyAt(0)));
    });

    test('不同实例的键互不相同', () {
      expect(CreateTripKeys().trip, isNot(CreateTripKeys().trip));
    });
  });
}
