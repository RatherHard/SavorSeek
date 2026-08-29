import 'package:flutter/foundation.dart';

import 'package:savorseek/features/explore/map_viewport.dart';

/// Immutable snapshot of the map and trip context at command submission time.
@immutable
class AgentSubmitContext {
  const AgentSubmitContext({
    this.mapViewport,
    this.selectedPlaceIds = const [],
    this.tripId,
    this.tripRevision,
  });

  final AgentMapViewport? mapViewport;
  final List<String> selectedPlaceIds;
  final String? tripId;
  final int? tripRevision;

  Map<String, dynamic> toJson() => {
    if (mapViewport != null) 'mapViewport': mapViewport!.toJson(),
    'selectedPlaceIds': List.unmodifiable(selectedPlaceIds),
    if (tripId != null) 'tripId': tripId,
    if (tripRevision != null) 'tripRevision': tripRevision,
  };
}

@immutable
class AgentMapViewport {
  const AgentMapViewport({
    required this.center,
    required this.zoom,
    required this.bounds,
  });

  factory AgentMapViewport.fromQuery(MapViewportQuery query) =>
      AgentMapViewport(
        center: query.center,
        zoom: query.zoom,
        bounds: query.bounds,
      );

  final MapViewportCenter center;
  final double zoom;
  final MapViewportBounds bounds;

  Map<String, dynamic> toJson() => {
    'center': {'latitude': center.latitude, 'longitude': center.longitude},
    'zoom': zoom,
    'bounds': {
      'south': bounds.south,
      'west': bounds.west,
      'north': bounds.north,
      'east': bounds.east,
    },
  };
}
