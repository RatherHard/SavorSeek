import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/explore/explore_page.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/places/place_search_query.dart';

/// 可编程的检索仓库。
class StubPlaceRepository implements PlaceRepository {
  StubPlaceRepository({this.result, this.error});

  PlaceSearchResult? result;
  PlaceSearchException? error;
  final List<String> calls = [];

  @override
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  }) async {
    calls.add(keywords);
    final failure = error;
    if (failure != null) throw failure;
    return result ?? const PlaceSearchResult(places: [], fromCache: false);
  }

  @override
  Future<PlaceSearchResult> search(PlaceSearchQuery query) async {
    final failure = error;
    if (failure != null) throw failure;
    return result ?? const PlaceSearchResult(places: [], fromCache: false);
  }

  @override
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters = 3000,
    String? keywords,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return result ?? const PlaceSearchResult(places: [], fromCache: false);
  }
}

Place buildPlace({String id = 'p1', String name = '老长春烧烤'}) {
  return Place(
    id: id,
    name: name,
    category: '餐饮服务;中餐厅;烧烤',
    address: '中山区某路 1 号',
    latitude: 38.914003,
    longitude: 121.614682,
    fetchedAt: DateTime.now(),
  );
}

/// 探索页需要 ScaffoldMessenger 承载 SnackBar。
Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 在指令栏输入并提交。
Future<void> submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byType(IconButton).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未注入仓库时提交按钮保持禁用', (tester) async {
    await tester.pumpWidget(wrap(const ExplorePage()));

    await tester.enterText(find.byType(TextField), '烧烤');
    await tester.pump();

    final bar = tester.widget<AgentCommandBar>(find.byType(AgentCommandBar));
    expect(bar.onSubmit, isNull);
  });

  testWidgets('指令栏提交后触发检索', (tester) async {
    final repository = StubPlaceRepository(
      result: PlaceSearchResult(places: [buildPlace()], fromCache: false),
    );
    await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));

    await submit(tester, '  烧烤  ');

    // 指令栏负责去空格，检索层收到的应是干净的关键词。
    expect(repository.calls, ['烧烤']);
  });

  group('四类失败提示各不相同（设计文档 §12）', () {
    testWidgets('空结果说明没有相符地点，且不给重试', (tester) async {
      final repository = StubPlaceRepository(
        result: const PlaceSearchResult(places: [], fromCache: false),
      );
      await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));

      await submit(tester, '不存在的店');

      expect(find.textContaining('没有找到与「不存在的店」相符的地点'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('Key 缺失属配置问题，不提供重试', (tester) async {
      final repository = StubPlaceRepository(
        error: const PlaceSearchException(
          '服务端未配置地点检索所需的密钥，请联系管理员。',
          failure: PlaceSearchFailure.providerKeyMissing,
        ),
      );
      await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));

      await submit(tester, '烧烤');

      expect(find.textContaining('未配置地点检索所需的密钥'), findsOneWidget);
      // 重试永远不会成功，给按钮只会让用户徒劳。
      expect(find.text('重试'), findsNothing);
      expect(find.byIcon(Icons.vpn_key_off_outlined), findsOneWidget);
    });

    testWidgets('网络失败提供重试', (tester) async {
      final repository = StubPlaceRepository(
        error: const PlaceSearchException(
          '无法连接地点检索服务，请检查网络后重试。',
          failure: PlaceSearchFailure.network,
        ),
      );
      await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));

      await submit(tester, '烧烤');

      expect(find.textContaining('无法连接地点检索服务'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    });

    testWidgets('视野无效的提示指向调整地图', (tester) async {
      final repository = StubPlaceRepository(
        error: const PlaceSearchException(
          '当前地图位置无效（纬度超出有效范围），请移动地图后重试。',
          failure: PlaceSearchFailure.invalidRequest,
        ),
      );
      await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));

      await submit(tester, '烧烤');

      expect(find.textContaining('当前地图位置无效'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  testWidgets('重试复用上次关键词', (tester) async {
    final repository = StubPlaceRepository(
      error: const PlaceSearchException(
        '网络异常',
        failure: PlaceSearchFailure.network,
      ),
    );
    await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));
    await submit(tester, '烧烤');

    repository.error = null;
    repository.result = PlaceSearchResult(
      places: [buildPlace()],
      fromCache: false,
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(repository.calls, ['烧烤', '烧烤']);
    expect(find.text('重试'), findsNothing);
  });
}
