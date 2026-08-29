import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/agent/agent_context.dart';
import 'package:savorseek/features/explore/map_viewport.dart';

void main() {
  test('serializes the map context with selected places and trip revision', () {
    final query = buildMapViewportQuery(
      latitude: 39.9042,
      longitude: 116.4074,
      zoom: 13,
      width: 390,
      height: 700,
    );

    expect(query, isNotNull);
    final context = AgentSubmitContext(
      mapViewport: AgentMapViewport.fromQuery(query!),
      selectedPlaceIds: const ['place-1'],
      tripId: 'trip-1',
      tripRevision: 4,
    );

    expect(context.toJson(), {
      'mapViewport': {
        'center': {'latitude': 39.9042, 'longitude': 116.4074},
        'zoom': 13.0,
        'bounds': {
          'south': isA<double>(),
          'west': isA<double>(),
          'north': isA<double>(),
          'east': isA<double>(),
        },
      },
      'selectedPlaceIds': ['place-1'],
      'tripId': 'trip-1',
      'tripRevision': 4,
    });
  });

  test('keeps an empty context explicit without inventing viewport data', () {
    expect(const AgentSubmitContext().toJson(), {
      'selectedPlaceIds': <String>[],
    });
  });
}
