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
          ? rawItems.whereType<Map>().map(Map<String, dynamic>.from).toList(growable: false)
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
class AgentWorkspaceSnapshot {
  const AgentWorkspaceSnapshot({
    this.session,
    this.tasks = const [],
    this.recommendations = const [],
    this.events = const [],
    this.draft,
    this.decisions = const [],
  });

  final AgentSession? session;
  final List<AgentTask> tasks;
  final List<AgentRecommendationSet> recommendations;
  final List<AgentEvent> events;
  final Map<String, dynamic>? draft;
  final List<Map<String, dynamic>> decisions;

  bool get awaitingDecision => decisions.any((item) => item['status'] == 'pending');

  factory AgentWorkspaceSnapshot.fromJson(Map<String, dynamic> json) {
    final rawSession = json['session'];
    final rawTasks = json['tasks'];
    final rawRecommendations = json['recommendations'];
    final rawEvents = json['events'];
    final rawDecisions = json['decisions'];
    final rawDrafts = json['drafts'];
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
      draft: _maps(rawDrafts).isEmpty ? null : _maps(rawDrafts).last,
    );
  }

  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList(growable: false)
      : const [];
}

int? _int(Object? value) => value is int ? value : int.tryParse('$value');
