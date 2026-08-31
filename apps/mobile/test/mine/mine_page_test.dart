import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/mine/mine_page.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/places/favorites_controller.dart';
import 'package:savorseek/features/places/place_models.dart';

class _FakeAuth implements AuthService {
  _FakeAuth();

  String? userId = 'user-a';
  final changes = StreamController<String?>.broadcast();

  @override
  String? get currentUserId => userId;

  @override
  String? get currentEmail => 'user@example.com';

  @override
  bool get isSignedIn => userId != null;

  @override
  Stream<String?> get userIdChanges => changes.stream;

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signUp({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signOut() async {
    userId = null;
    changes.add(null);
  }
}

class _FakeRepository implements FavoriteRepository {
  _FakeRepository(this.favorites);

  List<FavoritePlace> favorites;
  int listCalls = 0;

  @override
  Future<Set<String>> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  }) async => favorites.map((favorite) => favorite.place.id).toSet();

  @override
  Future<void> addFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {}

  @override
  Future<void> removeFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {}

  @override
  Future<List<FavoritePlace>> listFavorites({
    int limit = 20,
    int offset = 0,
  }) async {
    listCalls++;
    return favorites.skip(offset).take(limit).toList(growable: false);
  }
}

Place _place(String id, String name) => Place(
  id: id,
  name: name,
  category: '餐饮服务;中餐厅',
  address: '海边路 1 号',
  fetchedAt: DateTime(2026, 8, 31),
);

FavoritePlace _favorite(String id, String name) => FavoritePlace(
  favoriteId: 'favorite-$id',
  place: _place(id, name),
  createdAt: DateTime(2026, 8, 31),
);

void main() {
  testWidgets('登录后显示收藏地点并隐藏设置', (tester) async {
    final auth = _FakeAuth();
    final repository = _FakeRepository([_favorite('place-1', '海边小馆')]);
    final controller = FavoritesController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.changes.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MinePage(auth: auth, favoriteController: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('海边小馆'), findsOneWidget);
    expect(find.textContaining('中餐厅 · 海边路 1 号 · 无坐标 · 更新于'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
    expect(find.byTooltip('取消收藏 海边小馆'), findsOneWidget);
  });

  testWidgets('重新进入我的页面时刷新收藏地点', (tester) async {
    final auth = _FakeAuth();
    final repository = _FakeRepository([_favorite('place-1', '海边小馆')]);
    final controller = FavoritesController(auth: auth, repository: repository);
    addTearDown(() {
      controller.dispose();
      auth.changes.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MinePage(
          auth: auth,
          favoriteController: controller,
          isActive: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.listCalls, 1);

    repository.favorites = [_favorite('place-2', '山城小店')];
    await tester.pumpWidget(
      MaterialApp(
        home: MinePage(
          auth: auth,
          favoriteController: controller,
          isActive: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.listCalls, 2);
    expect(find.text('山城小店'), findsOneWidget);
    expect(find.text('海边小馆'), findsNothing);
  });
}
