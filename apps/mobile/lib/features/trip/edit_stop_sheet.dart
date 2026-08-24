import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_models.dart';

/// 编辑节点表单的提交结果。
@immutable
class EditStopDraft {
  const EditStopDraft({required this.title, this.notes});

  final String title;

  /// 备注。null 表示清空——服务端把 btrim 后的空串归一为 NULL。
  ///
  /// 不用「null 表示不改」：清空与不改都会想用 null 表达，二义性只能靠额外哨兵值
  /// 解决。表单总是把两个字段一起送，因此 null 只有「清空」一个含义。
  final String? notes;
}

/// 弹出编辑节点表单，预填当前标题与备注。用户取消时返回 null。
///
/// 只改标题与备注：时间走改期表单，状态走菜单里的取消/恢复/删除。已完成与已跳过
/// 的项不可编辑（库端返回 22023），调用方不应为它们给出入口。
Future<EditStopDraft?> showEditStopSheet(
  BuildContext context, {
  required TripStop stop,
}) {
  return showModalBottomSheet<EditStopDraft>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _EditStopSheet(stop: stop),
  );
}

class _EditStopSheet extends StatefulWidget {
  const _EditStopSheet({required this.stop});

  final TripStop stop;

  @override
  State<_EditStopSheet> createState() => _EditStopSheetState();
}

class _EditStopSheetState extends State<_EditStopSheet> {
  /// 标题上限 120，与 `trip_items.title` 的 varchar(120) 一致。
  static const int _titleMaxLength = 120;

  /// 备注上限 1000，与 `trip_items.notes` 的 varchar(1000) 一致。
  static const int _noteMaxLength = 1000;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController = TextEditingController(
    text: widget.stop.title,
  );
  late final TextEditingController _noteController = TextEditingController(
    text: widget.stop.note ?? '',
  );

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final notes = _noteController.text.trim();
    Navigator.of(context).pop(
      EditStopDraft(
        title: _titleController.text.trim(),
        // 清空备注即传 null，由仓库层转成空串交给服务端归一。
        notes: notes.isEmpty ? null : notes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final isCancelled = widget.stop.status == TripItemStatus.cancelled;

    return Padding(
      // 键盘弹出时上推内容，否则输入框被遮住。
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('编辑节点', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '修改名称与备注。调整时间请用「改期」。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                // 已取消的项仍可编辑，但要说清它当前不在计划内，否则用户会以为
                // 改完就恢复了。
                if (isCancelled) ...[
                  const SizedBox(height: AppTokens.spaceSm),
                  Row(
                    children: [
                      Icon(
                        Icons.event_busy_outlined,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: AppTokens.spaceXs),
                      Expanded(
                        child: Text(
                          '此项已取消，编辑后仍需「恢复」才会回到计划中。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppTokens.spaceLg),
                TextFormField(
                  controller: _titleController,
                  maxLength: _titleMaxLength,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '节点名称',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    // 库端 btrim 后校验非空，这里提前拦住全空格标题，省一次往返。
                    if ((value?.trim() ?? '').isEmpty) return '请填写节点名称';
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextFormField(
                  controller: _noteController,
                  maxLength: _noteMaxLength,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '备注（可留空）',
                    hintText: '清空即删除原备注',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
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
                        child: const Text('保存'),
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
