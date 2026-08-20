import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

/// 底部 Agent 指令栏。
///
/// 本项目不采用传统对话式交互：用户像队长一样向一支拟人化 Agent 小队下达指令，
/// 因此这里是「指令输入」而非聊天气泡列表。指令栏固定在页面底部，不随地图滚动
/// 消失（地图占据除本栏外的全部可用空间）。
///
/// 当前仅实现输入与提交入口；需求解析（`FR-501`）与 Agent 编排尚未接入，
/// 提交后由 [onSubmit] 交给上层处理。
class AgentCommandBar extends StatefulWidget {
  const AgentCommandBar({super.key, this.onSubmit});

  /// 指令提交回调。为空时输入框仍可用但提交按钮禁用，
  /// 避免给出一个点了没有任何反馈的按钮。
  final ValueChanged<String>? onSubmit;

  @override
  State<AgentCommandBar> createState() => _AgentCommandBarState();
}

class _AgentCommandBarState extends State<AgentCommandBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 是否有可提交内容。空白指令不应触发 Agent 执行。
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncHasText);
  }

  void _syncHasText() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText == _hasText) return;
    setState(() => _hasText = hasText);
  }

  void _submit() {
    final command = _controller.text.trim();
    if (command.isEmpty) return;

    final onSubmit = widget.onSubmit;
    if (onSubmit == null) return;

    onSubmit(command);
    _controller.clear();
    _focusNode.unfocus();
  }

  @override
  void dispose() {
    _controller.removeListener(_syncHasText);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canSubmit = _hasText && widget.onSubmit != null;

    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: '向 Agent 小队下达指令',
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.spaceMd,
                      vertical: AppTokens.spaceSm + 2,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              IconButton.filled(
                onPressed: canSubmit ? _submit : null,
                icon: const Icon(Icons.arrow_upward),
                tooltip: '下达指令',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
