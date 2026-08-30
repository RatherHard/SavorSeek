import 'package:flutter/foundation.dart';

@immutable
class AgentSession {
  const AgentSession({
    required this.id,
    required this.title,
    required this.status,
    required this.projectionVersion,
  });

  final String id;
  final String title;
  final String status;
  final int projectionVersion;

  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
    id: '${json['id']}',
    title: '${json['title'] ?? ''}',
    status: '${json['status'] ?? 'idle'}',
    projectionVersion: _int(json['projection_version']) ?? 1,
  );
}

@immutable
class AgentTask {
  const AgentTask({
    required this.id,
    required this.role,
    required this.status,
    required this.progress,
    this.summary,
  });

  final String id;
  final String role;
  final String status;
  final int progress;
  final String? summary;

  factory AgentTask.fromJson(Map<String, dynamic> json) => AgentTask(
    id: '${json['id']}',
    role: '${json['role']}',
    status: '${json['status']}',
    progress: _int(json['progress']) ?? 0,
    summary: json['user_summary'] as String?,
  );
}

@immutable
class AgentRecommendationSet {
  const AgentRecommendationSet({required this.id, required this.items});

  final String id;
  final List<Map<String, dynamic>> items;

  factory AgentRecommendationSet.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return AgentRecommendationSet(
      id: '${json['id']}',
      items: rawItems is List
          ? List.unmodifiable(
              rawItems.whereType<Map>().map(Map<String, dynamic>.from),
            )
          : const [],
    );
  }
}

@immutable
class AgentEvent {
  const AgentEvent({
    required this.id,
    required this.sequence,
    required this.type,
    required this.payload,
  });

  final String id;
  final int sequence;
  final String type;
  final Map<String, dynamic> payload;

  factory AgentEvent.fromJson(Map<String, dynamic> json) => AgentEvent(
    id: '${json['eventId'] ?? json['id']}',
    sequence: _int(json['sequence']) ?? 0,
    type: '${json['eventType'] ?? json['event_type']}',
    payload: json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : const {},
  );
}

@immutable
class AgentEventBatch {
  const AgentEventBatch({this.events = const [], this.nextSequence = 0})
    : assert(nextSequence >= 0);

  final List<AgentEvent> events;
  final int nextSequence;

  factory AgentEventBatch.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'];
    final rawSequence = json['nextSequence'] ?? json['next_sequence'];
    final parsedSequence = _int(rawSequence) ?? 0;
    return AgentEventBatch(
      events: rawEvents is List
          ? List.unmodifiable(
              rawEvents.whereType<Map>().map(
                (item) => AgentEvent.fromJson(Map<String, dynamic>.from(item)),
              ),
            )
          : const [],
      nextSequence: parsedSequence < 0 ? 0 : parsedSequence,
    );
  }
}

@immutable
class AgentMemoryProposal {
  const AgentMemoryProposal({
    required this.id,
    required this.sessionId,
    this.taskId,
    required this.operation,
    required this.memoryKey,
    required this.proposedValue,
    this.evidenceRefs = const [],
    this.confidence,
    required this.status,
    this.captainValue,
    this.resolvedAt,
    this.createdAt,
  });

  final String id;
  final String sessionId;
  final String? taskId;
  final String operation;
  final String memoryKey;
  final Map<String, dynamic> proposedValue;
  final List<String> evidenceRefs;
  final double? confidence;
  final String status;
  final Map<String, dynamic>? captainValue;
  final String? resolvedAt;
  final String? createdAt;

  bool get isPending => status == 'proposed' || status == 'shown_to_captain';

  bool get isEditable =>
      isPending &&
      (memoryKey == 'avoid' || memoryKey == 'budget_per_person') &&
      operation != 'delete' &&
      isValidValue(memoryKey, proposedValue);

  static bool isValidValue(String memoryKey, Map<String, dynamic> value) {
    if (memoryKey == 'avoid') {
      final items = value['items'];
      return items is List &&
          items.isNotEmpty &&
          items.length <= 20 &&
          items.every(
            (item) =>
                item is String && item.trim().isNotEmpty && item.length <= 40,
          );
    }
    if (memoryKey == 'budget_per_person') {
      final maxMinor = value['maxMinor'];
      return maxMinor is int && maxMinor > 0 && maxMinor <= 100000000;
    }
    return false;
  }

  factory AgentMemoryProposal.fromJson(
    Map<String, dynamic> json,
  ) => AgentMemoryProposal(
    id: '${json['id']}',
    sessionId: '${json['sessionId'] ?? json['session_id']}',
    taskId: _stringOrNull(json['taskId'] ?? json['task_id']),
    operation: '${json['operation'] ?? 'create'}',
    memoryKey: '${json['memoryKey'] ?? json['memory_key'] ?? ''}',
    proposedValue: _immutableMap(
      json['proposedValue'] ?? json['proposed_value'],
    ),
    evidenceRefs: _stringList(json['evidenceRefs'] ?? json['evidence_refs']),
    confidence: _double(json['confidence']),
    status: '${json['status'] ?? 'proposed'}',
    captainValue: _nullableMap(json['captainValue'] ?? json['captain_value']),
    resolvedAt: _stringOrNull(json['resolvedAt'] ?? json['resolved_at']),
    createdAt: _stringOrNull(json['createdAt'] ?? json['created_at']),
  );
}

@immutable
class AgentWorkspaceSnapshot {
  const AgentWorkspaceSnapshot({
    this.session,
    this.tasks = const [],
    this.recommendations = const [],
    this.events = const [],
    this.draft,
    this.decisions = const [],
    this.memoryProposals = const [],
  });

  final AgentSession? session;
  final List<AgentTask> tasks;
  final List<AgentRecommendationSet> recommendations;
  final List<AgentEvent> events;
  final Map<String, dynamic>? draft;
  final List<Map<String, dynamic>> decisions;
  final List<AgentMemoryProposal> memoryProposals;

  bool get awaitingDecision =>
      decisions.any((item) => item['status'] == 'pending');

  Iterable<AgentMemoryProposal> get pendingMemoryProposals =>
      memoryProposals.where((proposal) => proposal.isPending);

  factory AgentWorkspaceSnapshot.fromJson(Map<String, dynamic> json) {
    final rawSession = json['session'];
    final rawTasks = json['tasks'];
    final rawRecommendations = json['recommendations'];
    final rawEvents = json['events'];
    final rawDecisions = json['decisions'];
    final rawDrafts = json['drafts'];
    final rawMemoryProposals =
        json['memoryProposals'] ?? json['memory_proposals'];
    return AgentWorkspaceSnapshot(
      session: rawSession is Map
          ? AgentSession.fromJson(Map<String, dynamic>.from(rawSession))
          : null,
      tasks: _maps(rawTasks).map(AgentTask.fromJson).toList(growable: false),
      recommendations: _maps(rawRecommendations)
          .map(AgentRecommendationSet.fromJson)
          .toList(growable: false),
      events: _maps(rawEvents).map(AgentEvent.fromJson).toList(growable: false),
      decisions: _maps(rawDecisions).toList(growable: false),
      memoryProposals: _maps(rawMemoryProposals)
          .map(AgentMemoryProposal.fromJson)
          .toList(growable: false),
      draft: _maps(rawDrafts).isEmpty ? null : _maps(rawDrafts).last,
    );
  }

  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList(growable: false)
      : const [];
}

int? _int(Object? value) => value is int ? value : int.tryParse('$value');

double? _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value');

String? _stringOrNull(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

List<String> _stringList(Object? value) =>
    value is List ? List.unmodifiable(value.whereType<String>()) : const [];

Map<String, dynamic> _immutableMap(Object? value) {
  final copied = _copyValue(value);
  return copied is Map<String, dynamic>
      ? Map.unmodifiable(copied)
      : const <String, dynamic>{};
}

Map<String, dynamic>? _nullableMap(Object? value) {
  if (value is! Map) return null;
  return _immutableMap(value);
}

Object? _copyValue(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        '${entry.key}': _copyValue(entry.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_copyValue));
  return value;
}
