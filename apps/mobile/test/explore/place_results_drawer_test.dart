import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/explore/place_results_drawer.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/places/favorites_controller.dart';
import 'package:savorseek/features/places/place_models.dart';

void main() {
  testWidgets('地点列表可以收起并再次展开', (tester) async {
    final favorites = FavoritesController(
      auth: const UnavailableAuthService(),
      repository: const UnavailableFavoriteRepository(),
    );
    addTearDown(favorites.dispose);

    final places = [
      Place(
        id: 'place-1',
        name: '海边小馆',
        fetchedAt: DateTime(2026, 8, 31),
        category: '餐饮服务;中餐厅',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceResultsDrawer(
            places: places,
            favorites: favorites,
            onSelect: (_) {},
          ),
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

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('海边小馆'), findsOneWidget);
  });

  testWidgets('部分结果为空时仍可以收起列表入口', (tester) async {
    final favorites = FavoritesController(
      auth: const UnavailableAuthService(),
      repository: const UnavailableFavoriteRepository(),
    );
    addTearDown(favorites.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceResultsDrawer(
            places: const [],
            favorites: favorites,
            onSelect: (_) {},
            isPartial: true,
          ),
        ),
      ),
    );

    expect(find.text('查看 0 个地点'), findsOneWidget);
    expect(find.text('部分地点已加载，部分区域暂不可用。'), findsOneWidget);
    expect(find.byTooltip('收起地点列表'), findsOneWidget);
  });
}
