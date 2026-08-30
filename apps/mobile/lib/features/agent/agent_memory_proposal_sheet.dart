import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/agent/agent_models.dart';

Future<Map<String, dynamic>?> showMemoryProposalEditor(
  BuildContext context,
  AgentMemoryProposal proposal,
) {
  if (!proposal.isEditable) return Future.value();
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _MemoryProposalEditor(proposal: proposal),
  );
}

class _MemoryProposalEditor extends StatefulWidget {
  const _MemoryProposalEditor({required this.proposal});

  final AgentMemoryProposal proposal;

  @override
  State<_MemoryProposalEditor> createState() => _MemoryProposalEditorState();
}

class _MemoryProposalEditorState extends State<_MemoryProposalEditor> {
  static const int _itemMaxLength = 40;
  static const int _maxItems = 20;
  static const int _budgetMaxMinor = 100000000;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _valueController;

  @override
  void initState() {
    super.initState();
    _valueController = TextEditingController(text: _initialValue());
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  String _initialValue() {
    if (widget.proposal.memoryKey == 'avoid') {
      final items = widget.proposal.proposedValue['items'];
      if (items is List) return items.whereType<String>().join('\n');
    }
    if (widget.proposal.memoryKey == 'budget_per_person') {
      final maxMinor = widget.proposal.proposedValue['maxMinor'];
      if (maxMinor is num) return '${maxMinor.toInt()}';
    }
    return '';
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final value = widget.proposal.memoryKey == 'avoid'
        ? _avoidValue()
        : _budgetValue();
    Navigator.of(context).pop(value);
  }

  Map<String, dynamic> _avoidValue() {
    final items = <String>[];
    for (final line in _valueController.text.split(RegExp(r'[\n,，]'))) {
      final item = line.trim();
      if (item.isNotEmpty && !items.contains(item)) items.add(item);
    }
    return {'items': items, 'note': _note};
  }

  Map<String, dynamic> _budgetValue() => {
    'maxMinor': int.parse(_valueController.text.trim()),
    'note': _note,
  };

  String? get _note {
    final note = widget.proposal.proposedValue['note'];
    return note is String && note.trim().isNotEmpty ? note : null;
  }

  String? _validate(String? raw) {
    final value = raw?.trim() ?? '';
    if (widget.proposal.memoryKey == 'avoid') {
      final items = value
          .split(RegExp(r'[\n,，]'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet();
      if (items.isEmpty) return '至少填写一项忌口';
      if (items.length > _maxItems) return '最多填写 $_maxItems 项';
      if (items.any((item) => item.length > _itemMaxLength)) {
        return '每项最多 $_itemMaxLength 个字';
      }
      return null;
    }
    if (!RegExp(r'^\d+$').hasMatch(value)) return '请输入整数金额（分）';
    final amount = int.tryParse(value);
    if (amount == null || amount <= 0) return '金额必须大于 0';
    if (amount > _budgetMaxMinor) return '金额超出可保存范围';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isAvoid = widget.proposal.memoryKey == 'avoid';
    final insets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAvoid ? '编辑饮食忌口' : '编辑人均预算',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextFormField(
                  controller: _valueController,
                  autofocus: true,
                  maxLines: isAvoid ? 5 : 1,
                  keyboardType: isAvoid
                      ? TextInputType.multiline
                      : TextInputType.number,
                  decoration: InputDecoration(
                    labelText: isAvoid ? '忌口（每行一项）' : '人均预算上限（分）',
                    hintText: isAvoid ? '例如：海鲜\n香菜' : '例如：15000',
                    border: const OutlineInputBorder(),
                  ),
                  validator: _validate,
                ),
                const SizedBox(height: AppTokens.spaceLg),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceMd),
                    Expanded(
                      child: FilledButton(
                        onPressed: _submit,
                        child: const Text('保存修改'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
