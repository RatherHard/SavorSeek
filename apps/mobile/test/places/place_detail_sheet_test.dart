import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/places/place_detail_sheet.dart';
import 'package:savorseek/features/places/place_models.dart';

Place buildPlace({
  String name = '老长春烧烤',
  String? category = '餐饮服务;中餐厅;烧烤',
  String? address = '中山区某路 1 号',
  DateTime? fetchedAt,
}) {
  return Place(
    id: 'place-1',
    name: name,
    category: category,
    address: address,
    latitude: 38.914003,
    longitude: 121.614682,
    fetchedAt: fetchedAt ?? DateTime.now(),
  );
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('PlaceDetailSheet', () {
    testWidgets('展示名称、类别、地址与信息时效', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlaceDetailSheet(
            place: buildPlace(
              fetchedAt: DateTime.now().subtract(const Duration(hours: 3)),
            ),
            onClose: () {},
          ),
        ),
      );

      expect(find.text('老长春烧烤'), findsOneWidget);
      // 类别取最末一级：最具体，也最贴近用户认知。
      expect(find.text('烧烤'), findsOneWidget);
      expect(find.text('中山区某路 1 号'), findsOneWidget);
      // 可解释性要求：必须让用户知道信息何时抓取。
      expect(find.text('信息更新于3 小时前'), findsOneWidget);
    });

    testWidgets('缺类别与地址时不渲染空行', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlaceDetailSheet(
            place: buildPlace(category: null, address: null),
            onClose: () {},
          ),
        ),
      );

      expect(find.byIcon(Icons.place_outlined), findsNothing);
      expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
    });

    testWidgets('未提供回调时加入行程按钮禁用并说明原因', (tester) async {
      await tester.pumpWidget(
        wrap(PlaceDetailSheet(place: buildPlace(), onClose: () {})),
      );

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(find.text('登录后即可把地点加入行程。'), findsOneWidget);
    });

    testWidgets('点击加入行程触发回调', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        wrap(
          PlaceDetailSheet(
            place: buildPlace(),
            onClose: () {},
            onAddToTrip: () async => calls++,
          ),
        ),
      );

      await tester.tap(find.text('加入行程'));
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('写入中禁用按钮，避免重复提交', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlaceDetailSheet(
            place: buildPlace(),
            onClose: () {},
            onAddToTrip: () async {},
            isAdding: true,
          ),
        ),
      );

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(find.text('正在加入…'), findsOneWidget);
    });

    testWidgets('关闭按钮触发回调', (tester) async {
      var closed = false;
      await tester.pumpWidget(
        wrap(
          PlaceDetailSheet(place: buildPlace(), onClose: () => closed = true),
        ),
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(closed, isTrue);
    });
  });

  group('formatFreshness', () {
    final now = DateTime(2026, 8, 23, 12);

    test('一分钟内显示刚刚', () {
      expect(
        formatFreshness(now.subtract(const Duration(seconds: 30)), now: now),
        '刚刚',
      );
    });

    test('分钟、小时、天各用对应粒度', () {
      expect(
        formatFreshness(now.subtract(const Duration(minutes: 5)), now: now),
        '5 分钟前',
      );
      expect(
        formatFreshness(now.subtract(const Duration(hours: 5)), now: now),
        '5 小时前',
      );
      expect(
        formatFreshness(now.subtract(const Duration(days: 5)), now: now),
        '5 天前',
      );
    });

    test('超过 30 天退回绝对日期', () {
      // 「45 天前」难以判断新鲜度，绝对日期更可读。
      expect(
        formatFreshness(now.subtract(const Duration(days: 45)), now: now),
        '2026-07-09',
      );
    });

    test('时钟偏差导致的未来时间不显示负数', () {
      expect(
        formatFreshness(now.add(const Duration(hours: 2)), now: now),
        '刚刚',
      );
    });
  });
}
