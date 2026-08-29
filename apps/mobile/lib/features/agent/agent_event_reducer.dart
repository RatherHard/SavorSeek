import 'package:savorseek/features/agent/agent_models.dart';

class AgentEventReducer {
  AgentEventReducer({Iterable<AgentEvent> initialEvents = const []}) {
    for (final event in initialEvents) {
      _eventIds.add(event.id);
      if (event.sequence > lastSequence) lastSequence = event.sequence;
    }
  }

  final Set<String> _eventIds = <String>{};
  int lastSequence = 0;
  bool needsSnapshot = false;

  bool accept(AgentEvent event) {
    if (_eventIds.contains(event.id)) return false;
    if (event.sequence > lastSequence + 1) {
      needsSnapshot = true;
      return false;
    }
    _eventIds.add(event.id);
    if (event.sequence > lastSequence) lastSequence = event.sequence;
    return true;
  }

  void replaceFromSnapshot(AgentWorkspaceSnapshot snapshot) {
    _eventIds
      ..clear()
      ..addAll(snapshot.events.map((event) => event.id));
    lastSequence = snapshot.events.fold<int>(
      0,
      (current, event) => event.sequence > current ? event.sequence : current,
    );
    needsSnapshot = false;
  }
}
