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
            'status': 'displayed',
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
      expect(snapshot.recommendations.single.status, 'displayed');
      expect(snapshot.recommendations.single.canCaptainDecide, isTrue);
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

  test(
    'defaults recommendation status to generated for legacy projections',
    () {
      final snapshot = AgentWorkspaceSnapshot.fromJson({
        'recommendations': [
          {
            'id': 'set-legacy',
            'items': [
              {'name': '旧店'},
            ],
          },
        ],
      });

      expect(snapshot.recommendations.single.status, 'generated');
      expect(snapshot.recommendations.single.canCaptainDecide, isTrue);
    },
  );

  test(
    'only generated and displayed recommendations accept captain actions',
    () {
      for (final status in [
        'generated',
        'displayed',
        'draft',
        'captain_selected',
        'rejected',
        'expired',
        'added_to_trip',
        'unknown',
      ]) {
        final set = AgentRecommendationSet(
          id: 'set-$status',
          items: const [],
          status: status,
        );

        expect(
          set.canCaptainDecide,
          status == 'generated' || status == 'displayed',
        );
      }
    },
  );

  test('decodes route draft title, place names, and revision', () {
    final draft = AgentTripDraft.fromJson({
      'id': 'draft-1',
      'trip_id': 'trip-1',
      'base_revision': 2,
      'proposed_title': '大连 · 晚餐',
      'status': 'proposed',
      'items': [
        {'itemType': 'place_visit', 'title': '海鲜面馆'},
        {'itemType': 'place_visit', 'title': '烧烤店'},
      ],
      'warnings': ['请确认营业时间'],
    });

    expect(draft.id, 'draft-1');
    expect(draft.tripId, 'trip-1');
    expect(draft.baseRevision, 2);
    expect(draft.title, '大连 · 晚餐');
    expect(draft.placeNames, ['海鲜面馆', '烧烤店']);
    expect(draft.warnings, ['请确认营业时间']);
    expect(draft.canApply, isTrue);
  });

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
