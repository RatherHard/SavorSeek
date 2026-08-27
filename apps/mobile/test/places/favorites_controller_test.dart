import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/places/favorites_controller.dart';

class _FakeAuth implements AuthService {
  String? userId;
  final changes = StreamController<String?>.broadcast();

  @override
  String? get currentUserId => userId;
  @override
  String? get currentEmail => null;
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

  void signInAs(String id) {
    userId = id;
    changes.add(id);
  }
}

class _FakeRepository implements FavoriteRepository {
  Set<String> ids = {};
  Object? error;
  final addCalls = <({String placeId, String key})>[];
  final removeCalls = <({String placeId, String key})>[];
  Completer<void>? addGate;
  Completer<void>? removeGate;

  @override
  Future<Set<String>> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  }) async {
    if (placeIds.isEmpty) return Set.unmodifiable(ids);
    return Set.unmodifiable(ids.where(placeIds.toSet().contains).toSet());
  }

  @override
  Future<void> addFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {
    addCalls.add((placeId: placeId, key: idempotencyKey));
    await addGate?.future;
    if (error case final Object failure) throw failure;
    ids.add(placeId);
  }

  @override
  Future<void> removeFavorite({
    required String placeId,
    required String idempotencyKey,
  }) async {
    removeCalls.add((placeId: placeId, key: idempotencyKey));
    await removeGate?.future;
    if (error case final Object failure) throw failure;
    ids.remove(placeId);
  }

  @override
  Future<List<FavoritePlace>> listFavorites({
    int limit = 20,
    int offset = 0,
  }) async => const [];
}

void main() {
  late _FakeAuth auth;
  late _FakeRepository repository;
  late FavoritesController controller;

  setUp(() {
    auth = _FakeAuth()..userId = 'user-a';
    repository = _FakeRepository();
    controller = FavoritesController(auth: auth, repository: repository);
  });

  tearDown(() {
    controller.dispose();
    auth.changes.close();
  });

  test('optimistically adds and settles a favorite', () async {
    final future = controller.toggle('place-1');
    expect(controller.isFavorite('place-1'), isTrue);
    expect(controller.mutationState('place-1'), FavoriteMutationState.saving);

    await future;
    expect(controller.mutationState('place-1'), FavoriteMutationState.favorite);
    expect(repository.addCalls, hasLength(1));
  });

  test('failed add rolls back and retry reuses its idempotency key', () async {
    repository.error = const FavoriteRepositoryException(
      'network',
      kind: FavoriteErrorKind.network,
    );
    await controller.toggle('place-1');
    expect(controller.isFavorite('place-1'), isFalse);
    expect(controller.errorFor('place-1'), isNotNull);

    repository.error = null;
    await controller.retry('place-1');
    expect(controller.isFavorite('place-1'), isTrue);
    expect(repository.addCalls[0].key, repository.addCalls[1].key);
  });

  test('duplicate taps for one place are ignored while pending', () async {
    repository.addGate = Completer<void>();
    final first = controller.toggle('place-1');
    await controller.toggle('place-1');
    expect(repository.addCalls, hasLength(1));

    repository.addGate!.complete();
    await first;
  });

  test('different places can be saved concurrently', () async {
    repository.addGate = Completer<void>();
    final first = controller.toggle('place-1');
    final second = controller.toggle('place-2');
    expect(repository.addCalls, hasLength(2));
    repository.addGate!.complete();
    await Future.wait([first, second]);
    expect(controller.favoriteIds, containsAll(['place-1', 'place-2']));
  });

  test('logout clears state and ignores a late mutation response', () async {
    repository.addGate = Completer<void>();
    final pending = controller.toggle('place-1');
    auth.signOut();
    await Future<void>.delayed(Duration.zero);
    expect(controller.favoriteIds, isEmpty);
    repository.addGate!.complete();
    await pending;
    expect(controller.favoriteIds, isEmpty);
  });
}
