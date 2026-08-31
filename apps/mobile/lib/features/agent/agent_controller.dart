import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/util/uuid.dart';
import 'package:savorseek/features/agent/agent_context.dart';
import 'package:savorseek/features/location/location_service.dart';
import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/agent/agent_event_reducer.dart';
import 'package:savorseek/features/agent/agent_repository.dart';
import 'package:savorseek/features/agent/route_trip_factory.dart';
import 'package:savorseek/features/auth/auth_service.dart';

class AgentController extends ChangeNotifier {
  AgentController({
    required this.repository,
    required this.auth,
    this.client,
    this.routeTripFactory,
  }) {
    _currentUserId = auth.currentUserId;
    _authSubscription = auth.userIdChanges.listen(_onUserChanged);
  }

  final AgentRepository repository;
  final AuthService auth;
  final SupabaseClient? client;
  final RouteTripFactory? routeTripFactory;
  AgentWorkspaceSnapshot _snapshot = const AgentWorkspaceSnapshot();
  RealtimeChannel? _channel;
  StreamSubscription<String?>? _authSubscription;
  final AgentEventReducer _events = AgentEventReducer();
  final Set<String> _inFlightOperations = <String>{};
  final Map<String, Object> _operationTokens = <String, Object>{};
  final Map<String, String> _clientRequestIds = <String, String>{};
  final Map<String, String> _operationIdempotencyKeys = <String, String>{};
  final Map<String, _PendingSubmission> _pendingSubmissions =
      <String, _PendingSubmission>{};
  String? _currentUserId;
  String? _sessionId;
  bool _isSubmitting = false;
  bool _isCreatingRouteTrip = false;
  String? _error;
  String? _lastFailedSubmission;
  int _lifecycleGeneration = 0;
  bool _isDisposed = false;
  Future<void>? _refreshInFlight;
  bool _refreshPending = false;

  AgentWorkspaceSnapshot get snapshot => _snapshot;
  bool get isSubmitting => _isSubmitting;
  bool get isCreatingRouteTrip => _isCreatingRouteTrip;
  String? get error => _error;
  bool get hasSession => _sessionId != null;
  bool get canRetrySubmit => _lastFailedSubmission != null && !_isSubmitting;

  bool isMemoryProposalInFlight(String proposalId) => _inFlightOperations.any(
    (operation) => operation.startsWith('memory:$proposalId:'),
  );
  Future<void> submitNearbyFoodRecommendations({
    required DeviceLocation location,
    AgentSubmitContext context = const AgentSubmitContext(),
  }) => submit(
    '推荐附近的美食',
    context: AgentSubmitContext(
      mapViewport: context.mapViewport,
      currentLocation: location,
      selectedPlaceIds: context.selectedPlaceIds,
      tripId: context.tripId,
      tripRevision: context.tripRevision,
    ),
    constraints: const {'keywords': '美食', 'resultLimit': 5},
  );
  Future<void> submit(
    String text, {
    AgentSubmitContext context = const AgentSubmitContext(),
    Map<String, dynamic> constraints = const {},
    String taskType = 'discover_places',
  }) async {
    final trimmed = text.trim();
    if (_isSubmitting ||
        _isCreatingRouteTrip ||
        trimmed.isEmpty ||
        !auth.isSignedIn) {
      return;
    }
    final stableContext = AgentSubmitContext(
      mapViewport: context.mapViewport,
      currentLocation: context.currentLocation,
      selectedPlaceIds: List.unmodifiable(context.selectedPlaceIds),
      tripId: context.tripId,
      tripRevision: context.tripRevision,
    );
    final stableConstraints = _copyMap(constraints);
    final signature = jsonEncode([
      trimmed,
      taskType,
      stableContext.toJson(),
      stableConstraints,
    ]);
    final requestId = _clientRequestIds.putIfAbsent(signature, _newRequestId);
    _pendingSubmissions[signature] = _PendingSubmission(
      text: trimmed,
      requestId: requestId,
      context: stableContext,
      constraints: stableConstraints,
      taskType: taskType,
    );
    _lastFailedSubmission = null;
    await _submitWithRequest(
      trimmed,
      requestId: requestId,
      context: stableContext,
      constraints: stableConstraints,
      taskType: taskType,
      signature: signature,
    );
  }

  Future<void> submitRoute(
    String text, {
    AgentSubmitContext context = const AgentSubmitContext(),
    Map<String, dynamic> constraints = const {},
  }) async {
    final factory = routeTripFactory;
    if (factory == null) {
      _error = '路线规划服务尚未配置。';
      notifyListeners();
      return;
    }
    if (_isSubmitting ||
        _isCreatingRouteTrip ||
        text.trim().isEmpty ||
        !auth.isSignedIn) {
      return;
    }
    final generation = _lifecycleGeneration;
    final userId = _currentUserId;
    final requestId = _newRequestId();
    _isCreatingRouteTrip = true;
    _error = null;
    notifyListeners();
    try {
      final trip = await factory.createRouteTrip(idempotencyKey: requestId);
      if (_isDisposed ||
          generation != _lifecycleGeneration ||
          userId != _currentUserId ||
          !auth.isSignedIn) {
        return;
      }
      final stableContext = AgentSubmitContext(
        mapViewport: context.mapViewport,
        currentLocation: context.currentLocation,
        selectedPlaceIds: List.unmodifiable(context.selectedPlaceIds),
        tripId: trip.id,
        tripRevision: trip.revision,
      );
      final stableConstraints = _copyMap(constraints);
      final submitSignature = jsonEncode([
        text.trim(),
        'plan_route',
        stableContext.toJson(),
        stableConstraints,
      ]);
      _pendingSubmissions[submitSignature] = _PendingSubmission(
        text: text.trim(),
        requestId: requestId,
        context: stableContext,
        constraints: stableConstraints,
        taskType: 'plan_route',
      );
      _lastFailedSubmission = null;
      await _submitWithRequest(
        text.trim(),
        requestId: requestId,
        context: stableContext,
        constraints: stableConstraints,
        taskType: 'plan_route',
        signature: submitSignature,
      );
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    } on Exception catch (error) {
      _error = error.toString();
      notifyListeners();
    } finally {
      if (!_isDisposed && generation == _lifecycleGeneration) {
        _isCreatingRouteTrip = false;
        notifyListeners();
      }
    }
  }

  Future<void> retrySubmit() async {
    final signature = _lastFailedSubmission;
    if (signature == null || _isSubmitting || !auth.isSignedIn) return;
    final request = _pendingSubmission(signature);
    if (request == null) return;
    await _submitWithRequest(
      request.text,
      requestId: request.requestId,
      context: request.context,
      constraints: request.constraints,
      taskType: request.taskType,
      signature: signature,
    );
  }

  Future<void> _submitWithRequest(
    String text, {
    required String requestId,
    required AgentSubmitContext context,
    required Map<String, dynamic> constraints,
    required String taskType,
    required String signature,
  }) async {
    final generation = _lifecycleGeneration;
    _isSubmitting = true;
    _error = null;
    notifyListeners();
    try {
      final result = await repository.submit(
        rawText: text,
        title: '美食探索',
        goal: text,
        clientRequestId: requestId,
        taskType: taskType,
        context: context.toJson(),
        constraints: constraints,
      );
      if (_isDisposed ||
          generation != _lifecycleGeneration ||
          !auth.isSignedIn) {
        return;
      }
      _lastFailedSubmission = null;
      _pendingSubmissions.remove(signature);
      _clientRequestIds.remove(signature);
      await _activate(result, generation: generation, userId: _currentUserId);
    } on AgentRepositoryException catch (error) {
      if (_isDisposed ||
          generation != _lifecycleGeneration ||
          !auth.isSignedIn) {
        return;
      }
      _lastFailedSubmission = signature;
      _error = error.message;
    } finally {
      if (!_isDisposed && generation == _lifecycleGeneration) {
        _isSubmitting = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() {
    final sessionId = _sessionId;
    if (sessionId == null || _isDisposed) return Future<void>.value();
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      _refreshPending = true;
      return inFlight;
    }
    final generation = _lifecycleGeneration;
    final future = _runRefresh(sessionId, generation);
    _refreshInFlight = future;
    future.whenComplete(() {
      if (_refreshInFlight != future || _isDisposed) return;
      _refreshInFlight = null;
      if (_refreshPending) {
        _refreshPending = false;
        unawaited(refresh());
      }
    });
    return future;
  }

  Future<void> _runRefresh(String sessionId, int generation) async {
    try {
      await _recover(sessionId, generation);
    } catch (error) {
      if (_isCurrent(sessionId, generation)) {
        _error = 'Agent 同步失败，请重试。';
        notifyListeners();
      }
    }
  }

  Future<void> _recover(String sessionId, int generation) async {
    if (!_isCurrent(sessionId, generation)) return;
    try {
      var snapshot = await repository.loadSession(sessionId);
      if (!_isCurrent(sessionId, generation)) return;
      _installSnapshot(snapshot, generation);

      var cursor = _events.lastSequence;
      var shouldReload = false;
      for (var page = 0; page < 50; page++) {
        final batch = await repository.listEvents(sessionId, cursor);
        if (!_isCurrent(sessionId, generation)) return;
        if (batch.events.isEmpty) break;

        final ordered = [...batch.events]
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
        for (final event in ordered) {
          _events.accept(event);
          if (_events.needsSnapshot) {
            shouldReload = true;
            break;
          }
        }
        if (shouldReload) break;

        final nextCursor = batch.nextSequence;
        if (nextCursor <= cursor) {
          shouldReload = true;
          break;
        }
        cursor = nextCursor;
      }

      if (shouldReload) {
        snapshot = await repository.loadSession(sessionId);
        if (!_isCurrent(sessionId, generation)) return;
        _installSnapshot(snapshot, generation);
      }

      final finalSnapshot = await repository.loadSession(sessionId);
      if (_isCurrent(sessionId, generation)) {
        _installSnapshot(finalSnapshot, generation);
      }
    } on AgentRepositoryException catch (error) {
      if (_isCurrent(sessionId, generation)) {
        _error = error.message;
        notifyListeners();
      }
    }
  }

  Future<void> cancel() => _runOperation('cancel', () async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await repository.cancel(sessionId);
    await refresh();
  });

  Future<void> selectRecommendation(AgentRecommendationSet set) {
    if (!set.canCaptainDecide) return Future<void>.value();
    final sessionId = _sessionId;
    if (sessionId == null || set.items.isEmpty) return Future<void>.value();
    return _runOperation('recommendation:${set.id}', () async {
      if (_sessionId != sessionId) return;
      await repository.selectRecommendation(
        sessionId: sessionId,
        recommendationSetId: set.id,
        placeNames: [
          for (final item in set.items)
            if (item['name'] is String) item['name'] as String,
        ],
      );
      if (_sessionId == sessionId) await refresh();
    });
  }

  Future<void> rejectRecommendation(AgentRecommendationSet set) {
    if (!set.canCaptainDecide) return Future<void>.value();
    final sessionId = _sessionId;
    if (sessionId == null) return Future<void>.value();
    return _runOperation('recommendation:${set.id}', () async {
      if (_sessionId != sessionId) return;
      await repository.rejectRecommendation(
        sessionId: sessionId,
        recommendationSetId: set.id,
      );
      if (_sessionId == sessionId) await refresh();
    });
  }

  Future<void> retryTask(AgentTask task) =>
      _runOperation('retry:${task.id}', () async {
        await repository.retryTask(task.id);
        await refresh();
      });

  Future<void> resolveDecision(
    Map<String, dynamic> decision,
    String optionId, {
    int? expectedRevision,
  }) {
    final id = decision['id'];
    if (id is! String || optionId.trim().isEmpty) return Future<void>.value();
    if (optionId == 'apply' && expectedRevision == null) {
      _error = '无法应用路线草案：缺少当前行程版本，请先刷新行程。';
      notifyListeners();
      return Future<void>.value();
    }
    final operation = 'decision:$id:$optionId';
    return _runOperation(operation, () async {
      final idempotencyKey = optionId == 'apply'
          ? _operationIdempotencyKeys.putIfAbsent(operation, _newRequestId)
          : null;
      await repository.resolveDecision(
        checkpointId: id,
        optionId: optionId,
        expectedRevision: expectedRevision,
        idempotencyKey: idempotencyKey,
      );
      _operationIdempotencyKeys.remove(operation);
      await refresh();
    });
  }

  Future<void> resolveMemoryProposal(
    AgentMemoryProposal proposal,
    String decision, {
    Map<String, dynamic>? editedValue,
  }) {
    if (!proposal.isPending ||
        proposal.sessionId != _sessionId ||
        isMemoryProposalInFlight(proposal.id) ||
        !const {'accept', 'reject', 'edit'}.contains(decision)) {
      return Future<void>.value();
    }
    if (decision == 'edit' &&
        (editedValue == null ||
            !proposal.isEditable ||
            !AgentMemoryProposal.isValidValue(
              proposal.memoryKey,
              editedValue,
            ))) {
      return Future<void>.value();
    }
    if (decision != 'edit' && editedValue != null) {
      return Future<void>.value();
    }
    final stableEditedValue = editedValue == null
        ? null
        : _copyMap(editedValue);
    final operation = 'memory:${proposal.id}:$decision';
    return _runOperation(operation, () async {
      await repository.resolveMemoryProposal(
        proposalId: proposal.id,
        decision: decision,
        editedValue: stableEditedValue,
      );
      await refresh();
    });
  }

  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
  }) {
    final operation = 'draft:$draftId';
    return _runOperation(operation, () async {
      final idempotencyKey = _operationIdempotencyKeys.putIfAbsent(
        operation,
        _newRequestId,
      );
      await repository.applyDraft(
        draftId: draftId,
        expectedRevision: expectedRevision,
        idempotencyKey: idempotencyKey,
      );
      _operationIdempotencyKeys.remove(operation);
      await refresh();
    });
  }

  Future<void> _runOperation(
    String operation,
    Future<void> Function() action,
  ) async {
    if (_isDisposed || _inFlightOperations.contains(operation)) return;
    final token = Object();
    final generation = _lifecycleGeneration;
    _inFlightOperations.add(operation);
    _operationTokens[operation] = token;
    try {
      await action();
    } on AgentRepositoryException catch (error) {
      if (!_isDisposed && generation == _lifecycleGeneration) {
        _error = error.message;
        notifyListeners();
      }
    } finally {
      if (_operationTokens[operation] == token) {
        _operationTokens.remove(operation);
        _inFlightOperations.remove(operation);
      }
    }
  }

  Future<void> _activate(
    AgentWorkspaceSnapshot value, {
    int? generation,
    String? userId,
  }) async {
    if (_isDisposed ||
        (generation != null && generation != _lifecycleGeneration) ||
        (userId != null && userId != _currentUserId) ||
        !auth.isSignedIn) {
      return;
    }
    final nextSessionId = value.session?.id;
    final changed = nextSessionId != _sessionId;
    if (changed) await _unsubscribe();
    if (_isDisposed ||
        (generation != null && generation != _lifecycleGeneration) ||
        (userId != null && userId != _currentUserId) ||
        !auth.isSignedIn) {
      return;
    }
    _sessionId = nextSessionId;
    _snapshot = value;
    _events.replaceFromSnapshot(value);
    _error = null;
    notifyListeners();
    if (nextSessionId != null && changed) {
      await _subscribe(nextSessionId);
    }
  }

  void _installSnapshot(AgentWorkspaceSnapshot value, int generation) {
    if (_isDisposed || generation != _lifecycleGeneration) return;
    _snapshot = value;
    _events.replaceFromSnapshot(value);
    notifyListeners();
  }

  Future<void> _subscribe(String sessionId) async {
    final supabase = client;
    if (supabase == null || _isDisposed) return;
    final generation = _lifecycleGeneration;
    _channel = supabase
        .channel('agent-session-$sessionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'squad_events',
          callback: (payload) {
            if (_isDisposed || _sessionId != sessionId) return;
            if (payload.newRecord['session_id'] != sessionId) return;
            final event = AgentEvent.fromJson(payload.newRecord);
            _events.accept(event);
            unawaited(refresh());
          },
        )
        .subscribe((status, [error]) {
          if (_isDisposed ||
              generation != _lifecycleGeneration ||
              _sessionId != sessionId) {
            return;
          }
          if (status == RealtimeSubscribeStatus.subscribed) {
            _error = null;
            notifyListeners();
            unawaited(refresh());
          } else if (status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut ||
              status == RealtimeSubscribeStatus.closed) {
            _error = 'Agent 实时同步已断开，请刷新重试。';
            notifyListeners();
          }
        });
  }

  Future<void> _unsubscribe() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await channel.unsubscribe();
  }

  void _onUserChanged(String? userId) {
    if (_isDisposed || userId == _currentUserId) return;
    _currentUserId = userId;
    _lifecycleGeneration++;
    _isSubmitting = false;
    _sessionId = null;
    _snapshot = const AgentWorkspaceSnapshot();
    _events.replaceFromSnapshot(_snapshot);
    _error = null;
    _lastFailedSubmission = null;
    _clientRequestIds.clear();
    _pendingSubmissions.clear();
    _operationIdempotencyKeys.clear();
    _refreshPending = false;
    _inFlightOperations.clear();
    _operationTokens.clear();
    notifyListeners();
    unawaited(_unsubscribe());
  }

  bool _isCurrent(String sessionId, int generation) =>
      !_isDisposed &&
      generation == _lifecycleGeneration &&
      sessionId == _sessionId &&
      auth.isSignedIn;

  _PendingSubmission? _pendingSubmission(String signature) {
    final requestId = _clientRequestIds[signature];
    if (requestId == null) return null;
    // The original arguments are intentionally kept in a separate map only
    // while retry is possible; this avoids reconstructing structured context.
    return _pendingSubmissions[signature];
  }

  static Map<String, dynamic> _copyMap(Map<String, dynamic> value) {
    final encoded = jsonDecode(jsonEncode(value));
    if (encoded is! Map) return <String, dynamic>{};
    return Map.unmodifiable(_copyValue(encoded) as Map<String, dynamic>);
  }

  static Object? _copyValue(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries)
          '${entry.key}': _copyValue(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_copyValue));
    }
    return value;
  }

  String _newRequestId() => generateUuidV4();

  @override
  void dispose() {
    _isDisposed = true;
    _lifecycleGeneration++;
    unawaited(_authSubscription?.cancel() ?? Future<void>.value());
    unawaited(_unsubscribe());
    super.dispose();
  }
}

class _PendingSubmission {
  const _PendingSubmission({
    required this.text,
    required this.requestId,
    required this.context,
    required this.constraints,
    required this.taskType,
  });

  final String text;
  final String requestId;
  final AgentSubmitContext context;
  final Map<String, dynamic> constraints;
  final String taskType;
}
