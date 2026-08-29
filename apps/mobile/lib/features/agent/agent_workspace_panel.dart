import 'package:flutter/material.dart';

import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/agent/agent_models.dart';

class AgentWorkspacePanel extends StatelessWidget {
  const AgentWorkspacePanel({super.key, required this.controller});

  final AgentController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    if (!controller.hasSession && controller.error == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topRight,
      child: Card(
        margin: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 320),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: controller.error != null
                ? _ErrorView(controller: controller)
                : _SessionView(controller: controller, snapshot: snapshot),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.controller});
  final AgentController controller;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Expanded(child: Text('Agent 暂不可用，请稍后重试。')),
          IconButton(
            onPressed: controller.refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '重试',
          ),
        ],
      );
}

class _SessionView extends StatelessWidget {
  const _SessionView({required this.controller, required this.snapshot});
  final AgentController controller;
  final AgentWorkspaceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final session = snapshot.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(session?.title ?? 'Agent 小队', style: Theme.of(context).textTheme.titleMedium)),
            if (session?.status == 'working' || session?.status == 'dispatching')
              IconButton(onPressed: controller.cancel, icon: const Icon(Icons.stop_circle_outlined), tooltip: '取消任务'),
          ],
        ),
        Text(_statusLabel(session?.status ?? 'idle')),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (final task in snapshot.tasks) _TaskTile(task: task),
              for (final recommendation in snapshot.recommendations)
                _RecommendationTile(controller: controller, set: recommendation),
              for (final decision in snapshot.decisions.where((item) => item['status'] == 'pending'))
                _DecisionTile(controller: controller, decision: decision),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final AgentTask task;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: const Icon(Icons.person_outline),
        title: Text(_roleLabel(task.role)),
        subtitle: Text(task.summary ?? _statusLabel(task.status)),
        trailing: SizedBox(width: 48, child: Text('${task.progress}%')),
      );
}

class _RecommendationTile extends StatelessWidget {
  const _RecommendationTile({required this.controller, required this.set});
  final AgentController controller;
  final AgentRecommendationSet set;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.restaurant_outlined),
            title: Text('${set.items.length} 条推荐'),
            subtitle: Text(set.items.take(2).map((item) => '${item['name'] ?? '地点'}').join('、')),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(onPressed: () => controller.selectRecommendation(set), icon: const Icon(Icons.check), label: const Text('选择')),
              TextButton.icon(onPressed: () => controller.rejectRecommendation(set), icon: const Icon(Icons.close), label: const Text('拒绝')),
            ],
          ),
        ],
      );
}

class _DecisionTile extends StatelessWidget {
  const _DecisionTile({required this.controller, required this.decision});
  final AgentController controller;
  final Map<String, dynamic> decision;

  @override
  Widget build(BuildContext context) {
    final options = decision['options'];
    if (options is! List) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(leading: const Icon(Icons.help_outline), title: Text('${decision['question'] ?? '请确认'}')),
        for (final option in options)
          if (option is Map && option['id'] is String)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => controller.resolveDecision(decision, option['id'] as String),
                child: Text('${option['label'] ?? option['id']}'),
              ),
            ),
      ],
    );
  }
}

String _statusLabel(String status) => switch (status) {
      'receiving_command' => '正在接收指令',
      'interpreting' => '正在理解需求',
      'dispatching' => '正在分派任务',
      'working' => '小队工作中',
      'awaiting_captain_decision' => '等待队长确认',
      'completed' => '任务完成',
      'partially_completed' => '部分完成',
      'cancelled' => '已取消',
      'failed' => '执行失败',
      _ => status,
    };

String _roleLabel(String role) => switch (role) {
      'result_coordinator' => '队务官',
      'intent_interpreter' => '需求分析员',
      'map_explorer' => '地图侦察员',
      'preference_advisor' => '口味顾问',
      'fact_checker' => '事实核验员',
      'recommendation_decider' => '推荐顾问',
      'route_planner' => '路线规划员',
      'content_researcher' => '内容研究员',
      _ => role,
    };
