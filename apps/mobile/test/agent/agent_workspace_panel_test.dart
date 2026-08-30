import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/agent/agent_repository.dart';
import 'package:savorseek/features/agent/agent_workspace_panel.dart';
import 'package:savorseek/features/auth/auth_service.dart';

class _Auth implements AuthService {
  final _changes = StreamController<String?>.broadcast();

  @override
  String? currentUserId = 'user-1';
  @override
  String? get currentEmail => null;
  @override
  bool get isSignedIn => currentUserId != null;
  @override
  Stream<String?> get userIdChanges => _changes.stream;
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
  Future<void> signOut() async {}

  Future<void> dispose() => _changes.close();
}

class _Repository implements AgentRepository {
  _Repository(this.initial);

  final AgentWorkspaceSnapshot initial;
  final calls = <String>[];

  @override
  Future<AgentWorkspaceSnapshot> submit({
    required String rawText,
    required String title,
    required String goal,
    required String clientRequestId,
    String taskType = 'discover_places',
    Map<String, dynamic> context = const {},
    Map<String, dynamic> constraints = const {},
  }) async => initial;

  @override
  Future<AgentWorkspaceSnapshot> loadSession(String sessionId) async => initial;
  @override
  Future<AgentEventBatch> listEvents(
    String sessionId,
    int afterSequence,
  ) async => AgentEventBatch(nextSequence: afterSequence);
  @override
  Future<void> cancel(String sessionId) async {}
  @override
  Future<void> retryTask(String taskId) async {}
  @override
  Future<void> selectRecommendation({
    required String sessionId,
    required String recommendationSetId,
    required List<String> placeNames,
  }) async {}
  @override
  Future<void> rejectRecommendation({
    required String sessionId,
    required String recommendationSetId,
  }) async {}
  @override
  Future<void> resolveDecision({
    required String checkpointId,
    required String optionId,
    int? expectedRevision,
    String? idempotencyKey,
  }) async {}
  @override
  Future<void> resolveMemoryProposal({
    required String proposalId,
    required String decision,
    Map<String, dynamic>? editedValue,
  }) async => calls.add('$proposalId:$decision');
  @override
  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
    required String idempotencyKey,
  }) async {}
}

void main() {
  testWidgets('shows and accepts a pending memory proposal', (tester) async {
    final auth = _Auth();
    final repository = _Repository(
      AgentWorkspaceSnapshot(
        session: const AgentSession(
          id: 'session-1',
          title: '探索',
          status: 'awaiting_captain_decision',
          projectionVersion: 1,
        ),
        memoryProposals: [
          const AgentMemoryProposal(
            id: 'proposal-1',
            sessionId: 'session-1',
            operation: 'create',
            memoryKey: 'avoid',
            proposedValue: {
              'items': ['海鲜'],
            },
            status: 'proposed',
          ),
        ],
      ),
    );
    final controller = AgentController(repository: repository, auth: auth);

    await controller.submit('找晚餐');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AgentWorkspacePanel(controller: controller)),
      ),
    );

    expect(find.text('记忆提案'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.textContaining('海鲜'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(repository.calls, contains('proposal-1:accept'));
    controller.dispose();
    await auth.dispose();
  });
}
