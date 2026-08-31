import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/explore/place_results_drawer.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/places/favorites_controller.dart';
import 'package:savorseek/features/places/place_models.dart';

Place _place(String id, String name) => Place(
  id: id,
  name: name,
  fetchedAt: DateTime(2026, 8, 31),
  category: '餐饮服务;中餐厅',
);

FavoritesController _favorites() => FavoritesController(
  auth: const UnavailableAuthService(),
  repository: const UnavailableFavoriteRepository(),
);

Widget _host(Widget child, {double width = 400, double height = 800}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: width, height: height, child: child),
      ),
    );

void main() {
  testWidgets('地点列表可以收起并再次展开', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (_) {},
        ),
      ),
    );

    expect(find.text('查看 1 个地点'), findsOneWidget);
    expect(find.byTooltip('收起地点列表'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('海边小馆'), findsOneWidget);

    await tester.tap(find.byTooltip('收起地点列表'));
    await tester.pumpAndSettle();
    expect(find.text('海边小馆'), findsNothing);
    expect(find.byTooltip('展开地点列表'), findsOneWidget);

    await tester.tap(find.byTooltip('展开地点列表'));
    await tester.pumpAndSettle();
    expect(find.text('查看 1 个地点'), findsOneWidget);
    expect(find.byTooltip('收起地点列表'), findsOneWidget);
  });

  testWidgets('宽屏使用浮动面板并限制在地图区域内', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          layout: PlaceResultsLayout.auto,
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (_) {},
        ),
        width: 1024,
        height: 768,
      ),
    );

    final panel = tester.getRect(find.byType(AnimatedContainer));
    expect(panel.width, lessThanOrEqualTo(420));
    expect(panel.height, lessThanOrEqualTo(560));
    expect(panel.left, greaterThanOrEqualTo(0));
    expect(panel.bottom, lessThanOrEqualTo(768));
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.text('查看 1 个地点'), findsOneWidget);

    await tester.tap(find.byTooltip('收起地点列表'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开地点列表'), findsOneWidget);
    expect(tester.getSize(find.byType(AnimatedContainer)), const Size(52, 52));
  });

  testWidgets('可以显式选择底部布局和浮动布局', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          layout: PlaceResultsLayout.bottomSheet,
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (_) {},
        ),
        width: 1024,
        height: 768,
      ),
    );
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          layout: PlaceResultsLayout.floating,
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (_) {},
        ),
        width: 400,
        height: 800,
      ),
    );
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.text('查看 1 个地点'), findsOneWidget);
  });

  testWidgets('部分结果为空时仍可以收起列表入口', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          places: const [],
          favorites: favorites,
          onSelect: (_) {},
          isPartial: true,
        ),
      ),
    );

    expect(find.text('查看 0 个地点'), findsOneWidget);
    expect(find.text('部分地点已加载，部分区域暂不可用。'), findsOneWidget);
    expect(find.byTooltip('收起地点列表'), findsOneWidget);
  });

  testWidgets('地点卡片选择回调返回对应地点', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);
    Place? selected;

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (place) => selected = place,
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();

    await tester.tap(find.text('海边小馆'));
    expect(selected?.id, 'place-1');
  });

  testWidgets('分页状态显示加载更多和错误重试', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);
    var loadMoreCalls = 0;
    var retryCalls = 0;

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (_) {},
          hasMore: true,
          paginationError: '加载失败',
          onLoadMore: () => loadMoreCalls++,
          onRetryPagination: () => retryCalls++,
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();

    expect(find.text('已加载 1 个地点'), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.tap(find.text('重试'));
    expect(loadMoreCalls, 1);
    expect(retryCalls, 1);
  });

  testWidgets('折叠状态变化会通知调用方', (tester) async {
    final favorites = _favorites();
    addTearDown(favorites.dispose);
    final changes = <bool>[];

    await tester.pumpWidget(
      _host(
        PlaceResultsDrawer(
          places: [_place('place-1', '海边小馆')],
          favorites: favorites,
          onSelect: (_) {},
          onExpandedChanged: changes.add,
        ),
      ),
    );
    await tester.tap(find.byTooltip('收起地点列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开地点列表'));
    await tester.pumpAndSettle();

    expect(changes, [false, true]);
  });
}
