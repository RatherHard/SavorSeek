import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/agent/agent_place_projection.dart';

void main() {
  AgentWorkspaceSnapshot snapshotWithItems(List<Map<String, dynamic>> items) {
    return AgentWorkspaceSnapshot.fromJson({
      'session': {
        'id': 'session-1',
        'title': '探索',
        'status': 'completed',
        'projection_version': 2,
      },
      'recommendations': [
        {'id': 'set-1', 'status': 'displayed', 'items': items},
      ],
    });
  }

  Map<String, dynamic> placeSnapshot({String id = 'place-1'}) => {
    'id': id,
    'provider_place_id': 'amap-$id',
    'name': '老长春烧烤',
    'category': '餐饮服务;中餐厅;烧烤',
    'address': '中山区某路 1 号',
    'latitude': 38.914003,
    'longitude': 121.614682,
    'rating': 4.6,
    'cuisine_tags': ['烧烤'],
    'price_level': 2,
    'business_status': 'open',
    'coordinate_system': 'gcj02',
    'fetched_at': '2026-08-31T10:00:00Z',
  };

  test('projects canonical recommendation snapshots into Places', () {
    final projection = projectAgentPlaces(
      snapshotWithItems([
        {'name': '老长春烧烤', 'placeSnapshot': placeSnapshot()},
      ]),
    );

    expect(projection, isNotNull);
    expect(projection!.places.single.id, 'place-1');
    expect(projection.places.single.primaryCategory, '烧烤');
    expect(projection.places.single.hasCoordinates, isTrue);
    expect(projection.skippedItems, 0);
  });

  test('skips legacy or malformed items without losing valid places', () {
    final projection = projectAgentPlaces(
      snapshotWithItems([
        {'name': '旧店'},
        {
          'name': '坏店',
          'placeSnapshot': {'name': '坏店'},
        },
        {'name': '好店', 'placeSnapshot': placeSnapshot(id: 'place-2')},
      ]),
    );

    expect(projection!.places.map((place) => place.id), ['place-2']);
    expect(projection.skippedItems, 2);
    expect(projection.isPartial, isTrue);
  });

  test('does not project rejected recommendation sets', () {
    final snapshot = AgentWorkspaceSnapshot.fromJson({
      'session': {
        'id': 'session-1',
        'status': 'completed',
        'projection_version': 2,
      },
      'recommendations': [
        {
          'id': 'set-1',
          'status': 'rejected',
          'items': [
            {'placeSnapshot': placeSnapshot()},
          ],
        },
      ],
    });

    expect(projectAgentPlaces(snapshot), isNull);
  });
}
