import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/util/uuid.dart';
import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/agent/agent_event_reducer.dart';
import 'package:savorseek/features/agent/agent_repository.dart';

class AgentController extends ChangeNotifier {
  AgentController({required this.repository, SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final AgentRepository repository;
  final SupabaseClient _client;
  AgentWorkspaceSnapshot _snapshot = const AgentWorkspaceSnapshot();
  RealtimeChannel? _channel;
  AgentEventReducer _events = AgentEventReducer();
  String? _sessionId;
  bool _isSubmitting = false;
  String? _error;

  AgentWorkspaceSnapshot get snapshot => _snapshot;
  bool get isSubmitting => _isSubmitting;
  String? get error => _error;
  bool get hasSession => _sessionId != null;

  Future<void> submit(String text) async {
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
        constraints: const {},
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
      await repository.rejectRecommendation(sessionId: sessionId, recommendationSetId: set.id);
      await refresh();
    } on AgentRepositoryException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> resolveDecision(Map<String, dynamic> decision, String optionId) async {
    final id = decision['id'];
    if (id is! String) return;
    try {
      await repository.resolveDecision(checkpointId: id, optionId: optionId);
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
    await _channel?.unsubscribe();
    _channel = _client
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
