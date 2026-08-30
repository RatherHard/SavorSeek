import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/agent/agent_memory_proposal_sheet.dart';
import 'package:savorseek/features/agent/agent_models.dart';

class AgentWorkspacePanel extends StatefulWidget {
  const AgentWorkspacePanel({
    super.key,
    required this.controller,
    this.tripRevision,
  });

  final AgentController controller;
  final int? tripRevision;

  @override
  State<AgentWorkspacePanel> createState() => _AgentWorkspacePanelState();
}

class _AgentWorkspacePanelState extends State<AgentWorkspacePanel> {
  bool _isExpanded = true;
  Timer? _collapseTimer;

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    if (!controller.hasSession && controller.error == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth - 24).clamp(48.0, double.infinity)
            : 360.0;
        final expandedWidth = availableWidth.clamp(48.0, 360.0);
        final expandedHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight - 24).clamp(48.0, 320.0)
            : 320.0;
        final panelWidth = _isExpanded ? expandedWidth : 52.0;
        final panelHeight = _isExpanded ? expandedHeight : 52.0;

        return Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: AnimatedContainer(
              duration: AppTokens.durationNormal,
              curve: Curves.easeOut,
              width: panelWidth,
              height: panelHeight,
              child: ClipRect(
                child: _isExpanded
                    ? OverflowBox(
                        alignment: Alignment.topRight,
                        minWidth: expandedWidth,
                        maxWidth: expandedWidth,
                        minHeight: expandedHeight,
                        maxHeight: expandedHeight,
                        child: Card(
                          margin: EdgeInsets.zero,
                          clipBehavior: Clip.antiAlias,
                          child: _ExpandedPanel(
                            controller: controller,
                            snapshot: snapshot,
                            tripRevision: widget.tripRevision,
                            onCollapse: () =>
                                setState(() => _isExpanded = false),
                          ),
                        ),
                      )
                    : Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: _CollapsedPanel(
                          onExpand: () => setState(() => _isExpanded = true),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CollapsedPanel extends StatelessWidget {
  const _CollapsedPanel({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '展开 Agent 小队',
    child: Center(
      child: IconButton(
        onPressed: onExpand,
        icon: const Icon(Icons.groups_outlined),
        tooltip: '展开 Agent 小队',
      ),
    ),
  );
}

class _ExpandedPanel extends StatelessWidget {
  const _ExpandedPanel({
    required this.controller,
    required this.snapshot,
    required this.tripRevision,
    required this.onCollapse,
  });

  final AgentController controller;
  final AgentWorkspaceSnapshot snapshot;
  final int? tripRevision;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: controller.error != null
          ? _ErrorView(controller: controller, onCollapse: onCollapse)
          : _SessionView(
              controller: controller,
              snapshot: snapshot,
              tripRevision: tripRevision,
              onCollapse: onCollapse,
            ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.controller, required this.onCollapse});
  final AgentController controller;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        onPressed: onCollapse,
        icon: const Icon(Icons.chevron_right),
        tooltip: '收起 Agent 小队',
      ),
      Expanded(
        child: Text(
          controller.error ?? 'Agent 暂不可用，请稍后重试。',
          semanticsLabel: 'Agent 错误：${controller.error ?? '暂不可用，请稍后重试'}',
        ),
      ),
      if (controller.canRetrySubmit)
        IconButton(
          onPressed: controller.retrySubmit,
          icon: const Icon(Icons.refresh),
          tooltip: '重试原指令',
        )
      else if (controller.hasSession)
        IconButton(
          onPressed: controller.refresh,
          icon: const Icon(Icons.refresh),
          tooltip: '重试同步',
        ),
    ],
  );
}

class _SessionView extends StatelessWidget {
  const _SessionView({
    required this.controller,
    required this.snapshot,
    this.tripRevision,
    required this.onCollapse,
  });
  final AgentController controller;
  final AgentWorkspaceSnapshot snapshot;
  final int? tripRevision;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final session = snapshot.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                session?.title ?? 'Agent 小队',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              onPressed: onCollapse,
              icon: const Icon(Icons.chevron_right),
              tooltip: '收起 Agent 小队',
            ),
            if (session?.status == 'working' ||
                session?.status == 'dispatching')
              IconButton(
                onPressed: controller.cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: '取消任务',
              ),
          ],
        ),
        Text(_statusLabel(session?.status ?? 'idle')),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (final task in snapshot.tasks)
                _TaskTile(controller: controller, task: task),
              for (final recommendation in snapshot.recommendations)
                _RecommendationTile(
                  controller: controller,
                  set: recommendation,
                ),
              for (final decision in snapshot.decisions.where(
                (item) => item['status'] == 'pending',
              ))
                _DecisionTile(
                  controller: controller,
                  decision: decision,
                  fallbackRevision: tripRevision,
                ),
              for (final proposal in snapshot.pendingMemoryProposals)
                _MemoryProposalTile(controller: controller, proposal: proposal),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.controller, required this.task});
  final AgentController controller;
  final AgentTask task;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: const Icon(Icons.person_outline),
    title: Text(_roleLabel(task.role)),
    subtitle: Text(task.summary ?? _statusLabel(task.status)),
    trailing:
        task.status == 'failed' ||
            task.status == 'timed_out' ||
            task.status == 'partial'
        ? IconButton(
            onPressed: () => controller.retryTask(task),
            icon: const Icon(Icons.refresh),
            tooltip: '重试任务',
          )
        : SizedBox(width: 48, child: Text('${task.progress}%')),
  );
}

class _RecommendationTile extends StatelessWidget {
  const _RecommendationTile({required this.controller, required this.set});
  final AgentController controller;
  final AgentRecommendationSet set;

  @override
  Widget build(BuildContext context) {
    final canDecide = set.canCaptainDecide;
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.restaurant_outlined),
          title: Text('${set.items.length} 条推荐'),
          subtitle: Text(
            '${_recommendationStatusLabel(set.status)}\n'
            '${set.items.take(2).map((item) => '${item['name'] ?? '地点'}').join('、')}',
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: canDecide
                  ? () => controller.selectRecommendation(set)
                  : null,
              icon: const Icon(Icons.check),
              label: const Text('选择'),
            ),
            TextButton.icon(
              onPressed: canDecide
                  ? () => controller.rejectRecommendation(set)
                  : null,
              icon: const Icon(Icons.close),
              label: const Text('拒绝'),
            ),
          ],
        ),
      ],
    );
  }
}

class _DecisionTile extends StatelessWidget {
  const _DecisionTile({
    required this.controller,
    required this.decision,
    this.fallbackRevision,
  });
  final AgentController controller;
  final Map<String, dynamic> decision;
  final int? fallbackRevision;

  @override
  Widget build(BuildContext context) {
    final options = decision['options'];
    if (options is! List) return const SizedBox.shrink();
    final revision =
        decision['expectedRevision'] ?? decision['expected_revision'];
    final expectedRevision = revision is num
        ? revision.toInt()
        : fallbackRevision;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text('${decision['question'] ?? '请确认'}'),
        ),
        for (final option in options)
          if (option is Map && option['id'] is String)
            Align(
              alignment: Alignment.centerRight,
              child: Builder(
                builder: (context) {
                  final optionId = option['id'] as String;
                  return TextButton(
                    onPressed: optionId == 'apply' && expectedRevision == null
                        ? null
                        : () => controller.resolveDecision(
                            decision,
                            optionId,
                            expectedRevision: expectedRevision,
                          ),
                    child: Text('${option['label'] ?? optionId}'),
                  );
                },
              ),
            ),
      ],
    );
  }
}

class _MemoryProposalTile extends StatelessWidget {
  const _MemoryProposalTile({required this.controller, required this.proposal});

  final AgentController controller;
  final AgentMemoryProposal proposal;

  @override
  Widget build(BuildContext context) {
    final isBusy = controller.isMemoryProposalInFlight(proposal.id);
    final value = _summary;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lightbulb_outline),
              title: const Text('记忆提案'),
              subtitle: Text('$_operationLabel：$value'),
            ),
            if (proposal.confidence != null)
              Text(
                '置信度 ${(proposal.confidence! * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (!proposal.isEditable &&
                proposal.memoryKey != 'avoid' &&
                proposal.memoryKey != 'budget_per_person')
              const Text('此类型暂不支持编辑。'),
            if (proposal.isPending)
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: isBusy
                        ? null
                        : () => controller.resolveMemoryProposal(
                            proposal,
                            'accept',
                          ),
                    child: const Text('保存'),
                  ),
                  TextButton(
                    onPressed: isBusy
                        ? null
                        : () => controller.resolveMemoryProposal(
                            proposal,
                            'reject',
                          ),
                    child: const Text('拒绝'),
                  ),
                  if (proposal.isEditable)
                    TextButton(
                      onPressed: isBusy ? null : () => _edit(context),
                      child: const Text('编辑'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String get _operationLabel => switch (proposal.operation) {
    'create' => '建议保存',
    'update' => '建议更新',
    'delete' => '建议删除',
    _ => '建议处理',
  };

  String get _summary {
    final value = proposal.proposedValue;
    if (proposal.memoryKey == 'avoid' && value['items'] is List) {
      return (value['items'] as List).whereType<String>().join('、');
    }
    if (proposal.memoryKey == 'budget_per_person' && value['maxMinor'] is num) {
      return '${(value['maxMinor'] as num) / 100} 元';
    }
    return proposal.memoryKey;
  }

  Future<void> _edit(BuildContext context) async {
    final editedValue = await showMemoryProposalEditor(context, proposal);
    if (editedValue == null || !context.mounted) return;
    await controller.resolveMemoryProposal(
      proposal,
      'edit',
      editedValue: editedValue,
    );
  }
}

String _recommendationStatusLabel(String status) => switch (status) {
  'draft' => '草稿',
  'generated' => '已生成，等待队长决定',
  'displayed' => '已展示，等待队长决定',
  'captain_selected' => '队长已选择',
  'rejected' => '已拒绝',
  'expired' => '已过期',
  'added_to_trip' => '已加入行程',
  _ => status,
};

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
