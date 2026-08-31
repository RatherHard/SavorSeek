import 'package:flutter/foundation.dart';

import 'package:savorseek/features/agent/agent_models.dart';
import 'package:savorseek/features/places/place_models.dart';

/// The place projection that ExplorePage can render from an Agent snapshot.
@immutable
class AgentPlaceProjection {
  const AgentPlaceProjection({
    required this.key,
    required this.places,
    this.skippedItems = 0,
  });

  final String key;
  final List<Place> places;
  final int skippedItems;

  bool get isPartial => skippedItems > 0;
}

/// Converts only canonical Agent recommendation snapshots into Places.
///
/// Legacy recommendation items intentionally do not get guessed or searched
/// again: without a stable place id and freshness data they cannot safely drive
/// a marker, favorite, or detail view.
AgentPlaceProjection? projectAgentPlaces(AgentWorkspaceSnapshot snapshot) {
  final activeSets = snapshot.recommendations
      .where(
        (set) =>
            set.status == 'generated' ||
            set.status == 'displayed' ||
            set.status == 'captain_selected',
      )
      .toList(growable: false);
  if (activeSets.isEmpty || snapshot.session == null) return null;

  final set = activeSets.last;
  final places = <Place>[];
  final seenIds = <String>{};
  var skippedItems = 0;
  for (final item in set.items) {
    final rawSnapshot = item['placeSnapshot'] ?? item['place_snapshot'];
    if (rawSnapshot is! Map) {
      skippedItems++;
      continue;
    }
    final json = Map<String, dynamic>.from(rawSnapshot);
    final id = json['id'];
    final name = json['name'];
    final fetchedAt = json['fetched_at'] ?? json['fetchedAt'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        fetchedAt is! String ||
        DateTime.tryParse(fetchedAt) == null) {
      skippedItems++;
      continue;
    }
    json['id'] = id.trim();
    json['name'] = name.trim();
    json['fetched_at'] = fetchedAt;
    try {
      final place = Place.fromJson(json);
      if (seenIds.add(place.id)) places.add(place);
    } on Exception {
      skippedItems++;
    }
  }

  return AgentPlaceProjection(
    key:
        '${snapshot.session!.id}:${snapshot.session!.projectionVersion}:${set.id}',
    places: List.unmodifiable(places),
    skippedItems: skippedItems,
  );
}
