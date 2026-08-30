import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/agent/agent_models.dart';

void main() {
  test('Given an event batch, When it is decoded, Then events and cursor are preserved', () {
    final batch = AgentEventBatch.fromJson({
      'events': [
        {
          'eventId': 'event-2',
          'sequence': 2,
          'eventType': 'task.succeeded',
          'payload': const {},
        },
      ],
      'nextSequence': 2,
    });

    expect(batch.events.single.id, 'event-2');
    expect(batch.nextSequence, 2);
    expect(() => batch.events.add(batch.events.single), throwsUnsupportedError);
  });

  test(
    'Given a projection, When it is decoded, Then its workspace data is typed',
    () {
      final snapshot = AgentWorkspaceSnapshot.fromJson({
        'session': {
          'id': 'session-1',
          'title': '晚餐探索',
          'status': 'working',
          'projection_version': 4,
        },
        'tasks': [
          {
            'id': 'task-1',
            'role': 'map_explorer',
            'status': 'running',
            'progress': 40,
            'user_summary': '正在搜索当前区域',
          },
        ],
        'recommendations': [
          {
            'id': 'set-1',
            'items': [
              {'name': '甲店', 'rank': 1},
            ],
          },
        ],
        'events': [
          {
            'eventId': 'event-1',
            'sequence': 1,
            'eventType': 'task.started',
            'payload': {'role': 'map_explorer'},
          },
        ],
        'decisions': [
          {'id': 'decision-1', 'status': 'pending', 'question': '是否应用？'},
        ],
        'memory_proposals': [
          {
            'id': 'proposal-1',
            'session_id': 'session-1',
            'operation': 'create',
            'memory_key': 'avoid',
            'proposed_value': {
              'items': ['海鲜'],
              'note': '来自队长指令',
            },
            'evidence_refs': ['evidence-1'],
            'confidence': 0.9,
            'status': 'proposed',
          },
        ],
      });

      expect(snapshot.session?.status, 'working');
      expect(snapshot.tasks.single.progress, 40);
      expect(snapshot.recommendations.single.items.single['name'], '甲店');
      expect(snapshot.events.single.type, 'task.started');
      expect(snapshot.awaitingDecision, isTrue);
      expect(snapshot.memoryProposals.single.memoryKey, 'avoid');
      expect(snapshot.memoryProposals.single.isPending, isTrue);
      expect(snapshot.memoryProposals.single.isEditable, isTrue);
      expect(
        () => (snapshot.memoryProposals.single.proposedValue['items'] as List)
            .add('花生'),
        throwsUnsupportedError,
      );
    },
  );

  test('Given no projection arrays, When it is decoded, Then empty collections are returned', () {
    final snapshot = AgentWorkspaceSnapshot.fromJson(const {});

    expect(snapshot.tasks, isEmpty);
    expect(snapshot.recommendations, isEmpty);
    expect(snapshot.events, isEmpty);
    expect(snapshot.decisions, isEmpty);
    expect(snapshot.memoryProposals, isEmpty);
    expect(snapshot.awaitingDecision, isFalse);
  });
}
