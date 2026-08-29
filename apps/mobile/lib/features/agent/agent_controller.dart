import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/util/uuid.dart';
import 'package:savorseek/features/agent/agent_context.dart';
import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/agent/agent_event_reducer.dart';
import 'package:savorseek/features/agent/agent_repository.dart';

class AgentController extends ChangeNotifier {
  AgentController({required this.repository, this._client});

  final AgentRepository repository;
  final SupabaseClient? _client;
  AgentWorkspaceSnapshot _snapshot = const AgentWorkspaceSnapshot();
  RealtimeChannel? _channel;
  final AgentEventReducer _events = AgentEventReducer();
  String? _sessionId;
  bool _isSubmitting = false;
  String? _error;

  AgentWorkspaceSnapshot get snapshot => _snapshot;
  bool get isSubmitting => _isSubmitting;
  String? get error => _error;
  bool get hasSession => _sessionId != null;

  Future<void> submit(
    String text, {
    AgentSubmitContext context = const AgentSubmitContext(),
    Map<String, dynamic> constraints = const {},
    String taskType = 'discover_places',
  }) async {
    if (_isSubmitting || text.trim().isEmpty) return;
    _isSubmitting = true;
    _error = null;
    notifyListeners();
    try {
      final result = await repository.submit(
        rawText: text.trim(),
        title: '美食探索',
        goal: text.trim(),
        clientRequestId: _newRequestId(),
        taskType: taskType,
        context: context.toJson(),
        constraints: constraints,
      );
      await _activate(result);
    } on AgentRepositoryException catch (error) {
      _error = error.message;
    } finally {
      _isSubmitting = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      await _activate(await repository.loadSession(sessionId));
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      await repository.cancel(sessionId);
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> selectRecommendation(AgentRecommendationSet set) async {
    final sessionId = _sessionId;
    if (sessionId == null || set.items.isEmpty) return;
    try {
      await repository.selectRecommendation(
        sessionId: sessionId,
        recommendationSetId: set.id,
        placeNames: [
          for (final item in set.items)
            if (item['name'] is String) item['name'] as String,
        ],
      );
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> rejectRecommendation(AgentRecommendationSet set) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      await repository.rejectRecommendation(
        sessionId: sessionId,
        recommendationSetId: set.id,
      );
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> retryTask(AgentTask task) async {
    try {
      await repository.retryTask(task.id);
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> resolveDecision(
    Map<String, dynamic> decision,
    String optionId, {
    int? expectedRevision,
  }) async {
    final id = decision['id'];
    if (id is! String || optionId.trim().isEmpty) return;
    if (optionId == 'apply' && expectedRevision == null) {
      _error = '无法应用路线草案：缺少当前行程版本，请先刷新行程。';
      notifyListeners();
      return;
    }
    try {
      await repository.resolveDecision(
        checkpointId: id,
        optionId: optionId,
        expectedRevision: expectedRevision,
        idempotencyKey: optionId == 'apply' ? _newRequestId() : null,
      );
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
  }) async {
    try {
      await repository.applyDraft(
        draftId: draftId,
        expectedRevision: expectedRevision,
        idempotencyKey: _newRequestId(),
      );
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> _activate(AgentWorkspaceSnapshot snapshot) async {
    final sessionId = snapshot.session?.id;
    if (sessionId != null && sessionId != _sessionId) {
      await _subscribe(sessionId);
    }
    _snapshot = snapshot;
    _events.replaceFromSnapshot(snapshot);
    _sessionId = sessionId;
    notifyListeners();
  }

  Future<void> _subscribe(String sessionId) async {
    final client = _client;
    if (client == null) return;
    await _channel?.unsubscribe();
    _channel = client
        .channel('agent-session-$sessionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'squad_events',
          callback: (payload) {
            if (payload.newRecord['session_id'] == sessionId) {
              final event = AgentEvent.fromJson(payload.newRecord);
              if (_events.accept(event) || _events.needsSnapshot) {
                unawaited(refresh());
              }
            }
          },
        )
        .subscribe();
  }

  String _newRequestId() => generateUuidV4();

  @override
  void dispose() {
    unawaited(_channel?.unsubscribe() ?? Future<void>.value());
    super.dispose();
  }
}
