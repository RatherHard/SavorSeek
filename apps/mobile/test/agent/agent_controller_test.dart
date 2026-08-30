import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/agent/agent_repository.dart';
import 'package:savorseek/features/auth/auth_service.dart';

class _FakeAuth implements AuthService {
  _FakeAuth();

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

  void switchUser(String? id) {
    userId = id;
    changes.add(id);
  }
}

class _FakeAgentRepository implements AgentRepository {
  final List<String> calls = [];
  final List<int> eventCursors = [];
  final List<AgentWorkspaceSnapshot> snapshots = [];
  final List<AgentEventBatch> batches = [];
  AgentRepositoryException? submitError;
  Completer<AgentWorkspaceSnapshot>? submitGate;
  String? submittedRequestId;
  final List<AgentMemoryProposal> memoryProposals = [];
  String? memoryProposalId;
  String? memoryDecision;
  Map<String, dynamic>? memoryEditedValue;
  AgentRepositoryException? memoryProposalError;
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
    submittedRequestId = clientRequestId;
    calls.add('submit');
    await submitGate?.future;
    final error = submitError;
    if (error != null) throw error;
    return snapshots.removeAt(0);
  }

  @override
  Future<AgentWorkspaceSnapshot> loadSession(String sessionId) async {
    calls.add('load');
    if (snapshots.isEmpty) return snapshot(sessionId, 1);
    return snapshots.removeAt(0);
  }

  @override
  Future<AgentEventBatch> listEvents(
    String sessionId,
    int afterSequence,
  ) async {
    calls.add('events');
    eventCursors.add(afterSequence);
    if (batches.isEmpty) return AgentEventBatch(nextSequence: afterSequence);
    return batches.removeAt(0);
  }

  @override
  Future<void> cancel(String sessionId) async => calls.add('cancel');

  @override
  Future<void> retryTask(String taskId) async => calls.add('retry');

  @override
  Future<void> selectRecommendation({
    required String sessionId,
    required String recommendationSetId,
    required List<String> placeNames,
  }) async => calls.add('select');

  @override
  Future<void> rejectRecommendation({
    required String sessionId,
    required String recommendationSetId,
  }) async => calls.add('reject');

  @override
  Future<void> resolveDecision({
    required String checkpointId,
    required String optionId,
    int? expectedRevision,
    String? idempotencyKey,
  }) async => calls.add('resolve');

  @override
  Future<void> resolveMemoryProposal({
    required String proposalId,
    required String decision,
    Map<String, dynamic>? editedValue,
  }) async {
    final error = memoryProposalError;
    if (error != null) throw error;
    memoryProposalId = proposalId;
    memoryDecision = decision;
    memoryEditedValue = editedValue;
    calls.add('memory:$decision');
  }

  @override
  Future<void> applyDraft({
    required String draftId,
    required int expectedRevision,
    required String idempotencyKey,
  }) async => calls.add('apply');
}

AgentWorkspaceSnapshot snapshot(String id, int sequence) =>
    AgentWorkspaceSnapshot(
      session: AgentSession(
        id: id,
        title: '探索',
        status: 'working',
        projectionVersion: sequence,
      ),
      events: [
        AgentEvent(
          id: 'event-$sequence',
          sequence: sequence,
          type: 'task.progressed',
          payload: const {},
        ),
      ],
    );

void main() {
  late _FakeAuth auth;
  late _FakeAgentRepository repository;
  late AgentController controller;

  setUp(() {
    auth = _FakeAuth()..userId = 'user-a';
    repository = _FakeAgentRepository();
    controller = AgentController(repository: repository, auth: auth);
  });

  tearDown(() async {
    controller.dispose();
    await auth.changes.close();
  });

  test(
    'submit activates the returned session and recovers event batches',
    () async {
      repository.snapshots.add(snapshot('session-1', 1));
      await controller.submit('找晚餐');
      expect(controller.hasSession, isTrue);
      expect(controller.snapshot.session?.id, 'session-1');

      repository.snapshots
        ..add(snapshot('session-1', 1))
        ..add(snapshot('session-1', 2));
      repository.batches.addAll([
        AgentEventBatch(
          events: [
            AgentEvent(
              id: 'event-2',
              sequence: 2,
              type: 'task.succeeded',
              payload: const {},
            ),
          ],
          nextSequence: 2,
        ),
        const AgentEventBatch(nextSequence: 2),
      ]);

      await controller.refresh();
      expect(repository.eventCursors, [1, 2]);
      expect(controller.snapshot.events.single.sequence, 2);
    },
  );

  test('logout clears private state and ignores the old session', () async {
    repository.snapshots.add(snapshot('session-1', 1));
    await controller.submit('找晚餐');

    auth.switchUser(null);
    await Future<void>.delayed(Duration.zero);

    expect(controller.hasSession, isFalse);
    expect(controller.snapshot.session, isNull);
    expect(controller.error, isNull);
  });

  test(
    'duplicate recommendation operations are suppressed while in flight',
    () async {
      repository.snapshots.add(snapshot('session-1', 1));
      await controller.submit('找晚餐');
      final set = const AgentRecommendationSet(
        id: 'set-1',
        items: [
          {'name': '甲店'},
        ],
      );

      final first = controller.selectRecommendation(set);
      final second = controller.selectRecommendation(set);
      await Future.wait([first, second]);

      expect(repository.calls.where((call) => call == 'select'), hasLength(1));
    },
  );

  test(
    'resolves a pending memory proposal and refreshes the session',
    () async {
      repository.snapshots.add(snapshot('session-1', 1));
      await controller.submit('找晚餐');
      final proposal = AgentMemoryProposal(
        id: 'proposal-1',
        sessionId: 'session-1',
        operation: 'create',
        memoryKey: 'avoid',
        proposedValue: const {
          'items': ['海鲜'],
        },
        status: 'proposed',
      );

      repository.snapshots.add(snapshot('session-1', 2));
      await controller.resolveMemoryProposal(
        proposal,
        'edit',
        editedValue: const {
          'items': ['海鲜', '香菜'],
        },
      );

      expect(repository.memoryProposalId, 'proposal-1');
      expect(repository.memoryDecision, 'edit');
      expect(repository.memoryEditedValue, {
        'items': ['海鲜', '香菜'],
      });
      expect(repository.calls, contains('memory:edit'));
    },
  );

  test('failed submit can retry with the same client request id', () async {
    repository.submitError = const AgentRepositoryException('网络不可用。');
    await controller.submit('找晚餐');
    final firstRequestId = repository.submittedRequestId;
    expect(controller.canRetrySubmit, isTrue);

    repository
      ..submitError = null
      ..snapshots.add(snapshot('session-1', 1));
    await controller.retrySubmit();

    expect(repository.submittedRequestId, firstRequestId);
    expect(controller.hasSession, isTrue);
  });
}
