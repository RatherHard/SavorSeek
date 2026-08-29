import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/auth/auth_service.dart';

abstract interface class AgentRepository {
  Future<AgentWorkspaceSnapshot> submit({
    required String rawText,
    required String title,
    required String goal,
    required String clientRequestId,
    String taskType = 'discover_places',
    Map<String, dynamic> context = const {},
    Map<String, dynamic> constraints = const {},
  });

  Future<AgentWorkspaceSnapshot> loadSession(String sessionId);
  Future<AgentEventBatch> listEvents(String sessionId, int afterSequence);
  Future<void> cancel(String sessionId);
  Future<void> retryTask(String taskId);

  Future<void> selectRecommendation({
    required String sessionId,
    required String recommendationSetId,
    required List<String> placeNames,
  });
  Future<void> rejectRecommendation({
    required String sessionId,
    required String recommendationSetId,
  });
  Future<void> resolveDecision({
    required String checkpointId,
    required String optionId,
    int? expectedRevision,
    String? idempotencyKey,
  });
  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
    required String idempotencyKey,
  });
}

class UnavailableAgentRepository implements AgentRepository {
  const UnavailableAgentRepository([this.reason]);
  final String? reason;

  @override
  Future<AgentWorkspaceSnapshot> submit({
    required String rawText,
    required String title,
    required String goal,
    required String clientRequestId,
    String taskType = 'discover_places',
    Map<String, dynamic> context = const {},
    Map<String, dynamic> constraints = const {},
  }) => _fail();

  @override
  Future<AgentWorkspaceSnapshot> loadSession(String sessionId) => _fail();

  @override
  Future<AgentEventBatch> listEvents(String sessionId, int afterSequence) =>
      _fail();

  @override
  Future<void> cancel(String sessionId) => _fail();

  @override
  Future<void> retryTask(String taskId) => _fail();

  @override
  Future<void> selectRecommendation({
    required String sessionId,
    required String recommendationSetId,
    required List<String> placeNames,
  }) => _fail();

  @override
  Future<void> rejectRecommendation({
    required String sessionId,
    required String recommendationSetId,
  }) => _fail();

  @override
  Future<void> resolveDecision({
    required String checkpointId,
    required String optionId,
    int? expectedRevision,
    String? idempotencyKey,
  }) => _fail();

  @override
  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
    required String idempotencyKey,
  }) => _fail();

  Future<Never> _fail() async =>
      throw AgentRepositoryException(reason ?? 'Agent 服务尚未配置。');
}

class SupabaseAgentRepository implements AgentRepository {
  SupabaseAgentRepository({required this.auth, SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final AuthService auth;
  final SupabaseClient _client;

  @override
  Future<AgentWorkspaceSnapshot> submit({
    required String rawText,
    required String title,
    required String goal,
    required String clientRequestId,
    String taskType = 'discover_places',
    Map<String, dynamic> context = const {},
    Map<String, dynamic> constraints = const {},
  }) async {
    _requireSession();
    final response = await _invoke({
      'command': 'submit_command',
      'clientRequestId': clientRequestId,
      'title': title,
      'goal': goal,
      'rawText': rawText,
      'taskType': taskType,
      'context': context,
      'constraints': constraints,
      'memoryPolicy': 'propose_only',
      'locale': 'zh-CN',
      'clientVersion': '0.1.0',
    });
    final sessionId = _string(response['sessionId']);
    return loadSession(sessionId);
  }

  @override
  Future<AgentWorkspaceSnapshot> loadSession(String sessionId) async {
    _requireSession();
    final response = await _invoke({
      'command': 'get_session',
      'sessionId': sessionId,
    });
    final projection = response['projection'];
    if (projection is! Map) {
      throw const AgentRepositoryException('Agent 返回内容异常。');
    }
    return AgentWorkspaceSnapshot.fromJson(
      Map<String, dynamic>.from(projection),
    );
  }

  @override
  Future<AgentEventBatch> listEvents(
    String sessionId,
    int afterSequence,
  ) async {
    _requireSession();
    final response = await _invoke({
      'command': 'list_events',
      'sessionId': sessionId,
      'afterSequence': afterSequence,
    });
    return AgentEventBatch.fromJson(response);
  }

  @override
  Future<void> cancel(String sessionId) async {
    _requireSession();
    await _invoke({'command': 'cancel_session', 'sessionId': sessionId});
  }

  @override
  Future<void> retryTask(String taskId) async {
    _requireSession();
    await _invoke({'command': 'retry_task', 'taskId': taskId});
  }

  @override
  Future<void> selectRecommendation({
    required String sessionId,
    required String recommendationSetId,
    required List<String> placeNames,
  }) async {
    _requireSession();
    await _invoke({
      'command': 'select_recommendation',
      'sessionId': sessionId,
      'recommendationSetId': recommendationSetId,
      'placeNames': placeNames,
    });
  }

  @override
  Future<void> rejectRecommendation({
    required String sessionId,
    required String recommendationSetId,
  }) async {
    _requireSession();
    await _invoke({
      'command': 'reject_recommendation',
      'sessionId': sessionId,
      'recommendationSetId': recommendationSetId,
    });
  }

  @override
  Future<void> resolveDecision({
    required String checkpointId,
    required String optionId,
    int? expectedRevision,
    String? idempotencyKey,
  }) async {
    _requireSession();
    final body = <String, dynamic>{
      'command': 'resolve_decision_checkpoint',
      'checkpointId': checkpointId,
      'selectedOptionId': optionId,
    };
    if (expectedRevision != null) {
      body['expectedRevision'] = expectedRevision;
    }
    if (idempotencyKey != null) {
      body['idempotencyKey'] = idempotencyKey;
    }
    await _invoke(body);
  }

  @override
  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
    required String idempotencyKey,
  }) async {
    _requireSession();
    await _invoke({
      'command': 'apply_trip_draft',
      'draftId': draftId,
      'expectedRevision': expectedRevision,
      'idempotencyKey': idempotencyKey,
    });
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final response = await _client.functions.invoke('agent', body: body);
      final data = response.data;
      if (data is! Map) throw const AgentRepositoryException('Agent 返回内容异常。');
      final result = Map<String, dynamic>.from(data);
      if (result['error'] != null) {
        throw AgentRepositoryException(
          '${result['detail'] ?? result['error']}',
        );
      }
      return result;
    } on FunctionException catch (error) {
      throw AgentRepositoryException('${error.details ?? 'Agent 请求失败。'}');
    } on SocketException {
      throw const AgentRepositoryException('网络不可用。');
    }
  }

  void _requireSession() {
    if (!auth.isSignedIn) {
      throw const AgentRepositoryException('登录后才能使用 Agent。');
    }
  }

  String _string(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    throw const AgentRepositoryException('Agent 会话标识缺失。');
  }
}

class AgentRepositoryException implements Exception {
  const AgentRepositoryException(this.message);
  final String message;

  @override
  String toString() => message;
}
