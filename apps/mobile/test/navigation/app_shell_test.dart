// Tristate 未经 package:flutter/semantics.dart 再导出，需直接从 dart:ui 引入。
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/app/app.dart';
import 'package:savorseek/app/app_dependencies.dart';
import 'package:savorseek/app/navigation/app_destination.dart';
import 'package:savorseek/app/navigation/app_shell.dart';
import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/explore/explore_page.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/mine/mine_page.dart';
import 'package:savorseek/features/trip/trip_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

/// 后端未配置形态：与 SavorSeekApp 缺省依赖一致，使断言不依赖真实网络。
const AppDependencies _offlineDependencies = AppDependencies(
  auth: UnavailableAuthService(),
  tripRepository: UnavailableTripRepository('测试环境未连接行程服务。'),
);

void main() {
  group('AppShell 主导航', () {
    testWidgets('默认停留在探索页', (tester) async {
      await tester.pumpWidget(const SavorSeekApp());

      expect(find.byType(ExplorePage), findsOneWidget);
      // 指令栏是探索页的固定组成部分，不随地图状态变化。
      expect(find.byType(AgentCommandBar), findsOneWidget);
    });

    testWidgets('导航栏展示三个入口且顺序与页面清单一致', (tester) async {
      await tester.pumpWidget(const SavorSeekApp());

      final labels = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .toList();

      expect(labels, ['探索', '行程', '我的']);
    });

    testWidgets('点击行程切换到行程页', (tester) async {
      await tester.pumpWidget(const SavorSeekApp());

      await tester.tap(find.text('行程'));
      await tester.pumpAndSettle();

      expect(find.text('行程暂时加载失败'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
    });

    testWidgets('点击我的展示四个职责分区', (tester) async {
      await tester.pumpWidget(const SavorSeekApp());

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      for (final section in MinePage.sections) {
        expect(find.text(section.label), findsOneWidget);
      }
    });

    testWidgets('三个页面始终在树上，切页不丢状态', (tester) async {
      await tester.pumpWidget(const SavorSeekApp());

      // IndexedStack 保留全部页面，使地图视野与滚动位置在切页后不重置。
      expect(find.byType(ExplorePage, skipOffstage: false), findsOneWidget);
      expect(find.byType(TripPage, skipOffstage: false), findsOneWidget);
      expect(find.byType(MinePage, skipOffstage: false), findsOneWidget);
    });

    testWidgets('可指定初始页面', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AppShell(
            initialDestination: AppDestination.mine,
            dependencies: _offlineDependencies,
          ),
        ),
      );

      expect(find.text('偏好分析'), findsOneWidget);
    });

    testWidgets('选中态与未选中态对读屏可区分', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const SavorSeekApp());

      // 选中态不能只靠颜色传达，必须落到语义树上（NFR-303）。
      SemanticsNode nodeFor(String label) => tester.getSemantics(
        find
            .ancestor(of: find.text(label), matching: find.byType(Semantics))
            .first,
      );

      // 未选中项应为明确的 isFalse 而非 none，否则读屏无法播报「未选中」。
      expect(nodeFor('探索').flagsCollection.isSelected, Tristate.isTrue);
      expect(nodeFor('行程').flagsCollection.isSelected, Tristate.isFalse);

      handle.dispose();
    });
  });
}
