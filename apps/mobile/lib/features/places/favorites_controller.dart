import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:savorseek/app/util/uuid.dart';
import 'package:savorseek/features/auth/auth_service.dart';

import 'favorite_repository.dart';

/// The visible state of one place's favorite action.
enum FavoriteMutationState { notFavorite, saving, favorite, removing }

enum FavoriteListStatus { idle, loading, loaded, empty, failed }

/// Coordinates the authenticated favorite projection shared by Explore and Mine.
class FavoritesController extends ChangeNotifier {
  FavoritesController({
    required AuthService auth,
    required FavoriteRepository repository,
  }) : this._(auth, repository);

  FavoritesController._(this._auth, this._repository) {
    _authSubscription = _auth.userIdChanges.listen(_onUserChanged);
  }

  final AuthService _auth;
  final FavoriteRepository _repository;
  StreamSubscription<String?>? _authSubscription;
  final Set<String> _favoriteIds = <String>{};
  final Map<String, FavoriteMutationState> _mutationStates = {};
  final Map<String, _FavoriteOperation> _operations = {};
  final Map<String, FavoriteRepositoryException> _errors = {};
  final Map<String, FavoritePlace> _removedFavorites = {};
  List<FavoritePlace> _favoritePlaces = const [];
  FavoriteListStatus _listStatus = FavoriteListStatus.idle;
  FavoriteRepositoryException? _listError;
  int _sessionGeneration = 0;
  int _readGeneration = 0;
  bool _disposed = false;

  Set<String> get favoriteIds => Set.unmodifiable(_favoriteIds);
  List<FavoritePlace> get favoritePlaces => List.unmodifiable(_favoritePlaces);
  FavoriteListStatus get listStatus => _listStatus;
  FavoriteRepositoryException? get listError => _listError;

  bool isFavorite(String placeId) => _favoriteIds.contains(placeId);

  FavoriteMutationState mutationState(String placeId) {
    return _mutationStates[placeId] ??
        (isFavorite(placeId)
            ? FavoriteMutationState.favorite
            : FavoriteMutationState.notFavorite);
  }

  FavoriteRepositoryException? errorFor(String placeId) => _errors[placeId];

  /// Loads the current user's ID projection, normally after app bootstrap.
  Future<void> loadFavoritePlaceIds({
    Iterable<String> placeIds = const <String>[],
  }) async {
    if (!_auth.isSignedIn) {
      _clearPrivateState();
      return;
    }
    final generation = _sessionGeneration;
    final readGeneration = ++_readGeneration;
    _setListState(FavoriteListStatus.loading);
    try {
      final ids = await _repository.loadFavoritePlaceIds(placeIds: placeIds);
      if (!_isCurrent(generation)) return;
      if (readGeneration != _readGeneration) return;
      final requestedIds = placeIds.toSet();
      if (requestedIds.isEmpty) {
        _favoriteIds
          ..clear()
          ..addAll(ids);
      } else {
        _favoriteIds
          ..removeWhere(requestedIds.contains)
          ..addAll(ids);
      }
      for (final placeId in _operations.keys.toList()) {
        if (!_isPending(placeId)) {
          _mutationStates.remove(placeId);
          _errors.remove(placeId);
        }
      }
      _setListState(
        ids.isEmpty ? FavoriteListStatus.empty : FavoriteListStatus.loaded,
      );
    } on FavoriteRepositoryException catch (error) {
      if (!_isCurrent(generation)) return;
      _setListState(FavoriteListStatus.failed, error: error);
    } on Exception {
      if (!_isCurrent(generation)) return;
      _setListState(
        FavoriteListStatus.failed,
        error: const FavoriteRepositoryException(
          '收藏服务暂时不可用，请稍后重试。',
          kind: FavoriteErrorKind.unavailable,
        ),
      );
    }
  }

  /// Loads Mine's favorite rows and refreshes the shared ID projection.
  Future<void> loadFavorites() async {
    if (!_auth.isSignedIn) {
      _clearPrivateState();
      return;
    }
    final generation = _sessionGeneration;
    final readGeneration = ++_readGeneration;
    _setListState(FavoriteListStatus.loading);
    try {
      final places = await _repository.listFavorites();
      if (!_isCurrent(generation)) return;
      if (readGeneration != _readGeneration) return;
      _favoritePlaces = List.unmodifiable(places);
      final pendingIds = _operations.keys.where(_isPending).toSet();
      _favoriteIds
        ..removeWhere((id) => !pendingIds.contains(id))
        ..addAll(places.map((favorite) => favorite.place.id));
      _setListState(
        places.isEmpty ? FavoriteListStatus.empty : FavoriteListStatus.loaded,
      );
    } on FavoriteRepositoryException catch (error) {
      if (!_isCurrent(generation)) return;
      _setListState(FavoriteListStatus.failed, error: error);
    } on Exception {
      if (!_isCurrent(generation)) return;
      _setListState(
        FavoriteListStatus.failed,
        error: const FavoriteRepositoryException(
          '收藏服务暂时不可用，请稍后重试。',
          kind: FavoriteErrorKind.unavailable,
        ),
      );
    }
  }

  /// Starts one place operation. A pending operation for another place is allowed.
  Future<void> toggle(String placeId) async {
    if (!_auth.isSignedIn || _isPending(placeId)) return;
    final desired = !isFavorite(placeId);
    final operation = _operations[placeId];
    final next = _FavoriteOperation(
      key: generateUuidV4(),
      desired: desired,
      sequence: (operation?.sequence ?? 0) + 1,
    );
    await _run(placeId, next);
  }

  /// Retries the last failed operation with the same idempotency key.
  Future<void> retry(String placeId) async {
    if (!_auth.isSignedIn || _isPending(placeId)) return;
    final operation = _operations[placeId];
    if (operation == null || _errors[placeId] == null) return;
    await _run(placeId, operation);
  }

  Future<void> _run(String placeId, _FavoriteOperation operation) async {
    _operations[placeId] = operation;
    _errors.remove(placeId);
    _mutationStates[placeId] = operation.desired
        ? FavoriteMutationState.saving
        : FavoriteMutationState.removing;
    if (operation.desired) {
      _favoriteIds.add(placeId);
    } else {
      _favoriteIds.remove(placeId);
    }
    if (!operation.desired &&
        _favoritePlaces.any((item) => item.place.id == placeId)) {
      final removed = _favoritePlaces.firstWhere(
        (item) => item.place.id == placeId,
      );
      _removedFavorites[placeId] = removed;
      _favoritePlaces = List.unmodifiable(
        _favoritePlaces.where((item) => item.place.id != placeId),
      );
    }
    notifyListeners();

    final mutationGeneration = _sessionGeneration;
    try {
      if (operation.desired) {
        await _repository.addFavorite(
          placeId: placeId,
          idempotencyKey: operation.key,
        );
      } else {
        await _repository.removeFavorite(
          placeId: placeId,
          idempotencyKey: operation.key,
        );
      }
      if (!_isCurrent(mutationGeneration) ||
          _operations[placeId] != operation) {
        return;
      }
      if (!operation.desired) {
        _removedFavorites.remove(placeId);
      }
      _mutationStates.remove(placeId);
      _errors.remove(placeId);
      notifyListeners();
    } on FavoriteRepositoryException catch (error) {
      _rollback(placeId, operation, mutationGeneration, error);
    } on Exception {
      _rollback(
        placeId,
        operation,
        mutationGeneration,
        const FavoriteRepositoryException(
          '收藏服务暂时不可用，请稍后重试。',
          kind: FavoriteErrorKind.unavailable,
        ),
      );
    }
  }

  void _rollback(
    String placeId,
    _FavoriteOperation operation,
    int generation,
    FavoriteRepositoryException error,
  ) {
    if (!_isCurrent(generation) || _operations[placeId] != operation) return;
    if (operation.desired) {
      _favoriteIds.remove(placeId);
      _mutationStates[placeId] = FavoriteMutationState.notFavorite;
    } else {
      _favoriteIds.add(placeId);
      _mutationStates[placeId] = FavoriteMutationState.favorite;
      final removed = _removedFavorites.remove(placeId);
      if (removed != null &&
          !_favoritePlaces.any((item) => item.place.id == placeId)) {
        _favoritePlaces = List.unmodifiable([..._favoritePlaces, removed]);
      }
    }
    _errors[placeId] = error;
    notifyListeners();
  }

  bool _isPending(String placeId) {
    final state = _mutationStates[placeId];
    return state == FavoriteMutationState.saving ||
        state == FavoriteMutationState.removing;
  }

  void _onUserChanged(String? userId) {
    ++_sessionGeneration;
    if (userId == null) {
      _clearPrivateState();
      return;
    }
    _favoriteIds.clear();
    _favoritePlaces = const [];
    _mutationStates.clear();
    _operations.clear();
    _removedFavorites.clear();
    _errors.clear();
    _setListState(FavoriteListStatus.idle);
    unawaited(loadFavoritePlaceIds());
  }

  void _clearPrivateState() {
    _favoriteIds.clear();
    _favoritePlaces = const [];
    _mutationStates.clear();
    _operations.clear();
    _removedFavorites.clear();
    _errors.clear();
    _listError = null;
    _setListState(FavoriteListStatus.idle);
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration && _auth.isSignedIn;

  void _setListState(
    FavoriteListStatus status, {
    FavoriteRepositoryException? error,
  }) {
    if (_disposed) return;
    _listStatus = status;
    _listError = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }
}

class _FavoriteOperation {
  const _FavoriteOperation({
    required this.key,
    required this.desired,
    required this.sequence,
  });

  final String key;
  final bool desired;
  final int sequence;
}
