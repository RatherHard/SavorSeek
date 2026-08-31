import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/app/config/amap_config.dart';
import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/explore/explore_page.dart';
import 'package:savorseek/features/location/location_service.dart';

void main() {
  group('ExplorePage 行为', () {
    test('首次定位相机以设备位置为中心', () {
      const location = DeviceLocation(latitude: 31.2304, longitude: 121.4737);

      final camera = cameraForDeviceLocation(location);

      expect(camera.target.latitude, closeTo(location.latitude, 0.000001));
      expect(camera.target.longitude, closeTo(location.longitude, 0.000001));
      expect(camera.zoom, 15);
    });

    test('地点详情打开时隐藏 Agent 工作区，关闭后恢复', () {
      expect(
        shouldShowExploreAgentPanel(
          hasAgentController: true,
          hasSelectedPlace: true,
        ),
        isFalse,
      );
      expect(
        shouldShowExploreAgentPanel(
          hasAgentController: true,
          hasSelectedPlace: false,
        ),
        isTrue,
      );
      expect(
        shouldShowExploreAgentPanel(
          hasAgentController: false,
          hasSelectedPlace: false,
        ),
        isFalse,
      );
    });
  });

  group('ExplorePage 布局', () {
    testWidgets('指令栏固定在底部，地图区域占据其余空间', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ExplorePage())),
      );

      final screenHeight = tester.getSize(find.byType(ExplorePage)).height;
      final barRect = tester.getRect(find.byType(AgentCommandBar));

      // 指令栏贴底。
      expect(barRect.bottom, moreOrLessEquals(screenHeight, epsilon: 0.5));
      // 指令栏不应占据大部分高度，地图才是主体。
      expect(barRect.height, lessThan(screenHeight / 3));
    });

    testWidgets('Android 不因 dart-define 缺失而判定未配置', (tester) async {
      // 回归用例：Android 的 Key 由构建期注入 AndroidManifest，
      // 不依赖 --dart-define。此前把两者混为一谈，导致正常启动时
      // 误判「未配置」并挡掉地图。测试环境无 dart-define 注入，
      // 此处必须为 false。
      expect(AmapConfig.isKeyMissing, isFalse);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ExplorePage())),
      );

      expect(find.text('地图不可用'), findsNothing);
      // 未同意合规声明时应停在告知卡片，而不是「地图不可用」。
      expect(find.text('地图服务说明'), findsOneWidget);
      expect(find.byType(AgentCommandBar), findsOneWidget);
    });

    test('空 Key 不下发给插件，避免覆盖 manifest 中的有效值', () {
      // 插件的 checkApiKey 只判空引用不判空串，传 '' 会以空 Key 覆盖
      // manifest 已注入的有效值，必须为 null。
      expect(AmapConfig.androidKey, isNull);
      expect(AmapConfig.iosKey, isNull);
    });
  });

  group('AmapConsent 合规闸门', () {
    test('初始为未同意，同意后置为 true 且只通知一次', () {
      final consent = AmapConsent();
      addTearDown(consent.dispose);

      var notifications = 0;
      consent.addListener(() => notifications++);

      expect(consent.agreed, isFalse);

      consent.agree();
      expect(consent.agreed, isTrue);
      expect(notifications, 1);

      // 重复同意不应重复通知。
      consent.agree();
      expect(notifications, 1);
    });

    testWidgets('告知卡片提供同意入口', (tester) async {
      var agreed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AmapConsentNotice(onAgree: () => agreed = true)),
        ),
      );

      expect(find.text('地图服务说明'), findsOneWidget);
      await tester.tap(find.text('同意并显示地图'));
      expect(agreed, isTrue);
    });
  });

  group('AgentCommandBar 指令栏', () {
    testWidgets('空白指令不可提交', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentCommandBar(onSubmit: (_) {})),
        ),
      );

      IconButton button() => tester.widget<IconButton>(find.byType(IconButton));
      expect(button().onPressed, isNull);

      // 仅空格也不算有效指令。
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(button().onPressed, isNull);

      await tester.enterText(find.byType(TextField), '找附近的本地菜');
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('提交后回调收到去空格的指令并清空输入', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentCommandBar(onSubmit: submitted.add)),
        ),
      );

      await tester.enterText(find.byType(TextField), '  每人 150 元，不去连锁店  ');
      await tester.pump();
      await tester.tap(find.byType(IconButton));
      await tester.pump();

      expect(submitted, ['每人 150 元，不去连锁店']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('未接入回调时提交按钮保持禁用', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AgentCommandBar())),
      );

      await tester.enterText(find.byType(TextField), '随便看看');
      await tester.pump();

      // Agent 编排未接入，不应给出点了没有反馈的按钮。
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
    });
  });
}
