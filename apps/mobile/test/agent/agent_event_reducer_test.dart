import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/agent/agent_event_reducer.dart';
import 'package:savorseek/features/agent/agent_models.dart';

AgentEvent event(String id, int sequence) => AgentEvent(
      id: id,
      sequence: sequence,
      type: 'task.progressed',
      payload: const {},
    );

void main() {
  test('Given a duplicate event, When it is accepted twice, Then the second is ignored', () {
    final reducer = AgentEventReducer();

    expect(reducer.accept(event('one', 1)), isTrue);
    expect(reducer.accept(event('one', 1)), isFalse);
    expect(reducer.lastSequence, 1);
  });

  test('Given a sequence gap, When a later event arrives, Then snapshot recovery is requested', () {
    final reducer = AgentEventReducer();

    expect(reducer.accept(event('two', 2)), isFalse);
    expect(reducer.needsSnapshot, isTrue);
  });

  test('Given a fresh snapshot, When it replaces local events, Then the reducer resumes', () {
    final reducer = AgentEventReducer()..accept(event('one', 1));
    reducer.needsSnapshot = true;
    reducer.replaceFromSnapshot(const AgentWorkspaceSnapshot(
      events: [
        AgentEvent(id: 'one', sequence: 1, type: 'task.started', payload: {}),
        AgentEvent(id: 'two', sequence: 2, type: 'task.succeeded', payload: {}),
      ],
    ));

    expect(reducer.needsSnapshot, isFalse);
    expect(reducer.lastSequence, 2);
    expect(reducer.accept(event('three', 3)), isTrue);
  });
}
