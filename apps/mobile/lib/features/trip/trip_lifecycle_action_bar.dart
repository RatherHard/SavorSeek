import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

class TripLifecycleActionBar extends StatelessWidget {
  const TripLifecycleActionBar({
    super.key,
    this.onComplete,
    this.onCancel,
    this.onAddStop,
  });

  final VoidCallback? onComplete;
  final VoidCallback? onCancel;
  final VoidCallback? onAddStop;

  @override
  Widget build(BuildContext context) {
    final hasLifecycleActions = onComplete != null || onCancel != null;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceSm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasLifecycleActions)
              Row(
                children: [
                  if (onComplete != null)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onComplete,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('完成行程'),
                      ),
                    ),
                  if (onComplete != null && onCancel != null)
                    const SizedBox(width: AppTokens.spaceSm),
                  if (onCancel != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.event_busy_outlined),
                        label: const Text('取消行程'),
                      ),
                    ),
                ],
              ),
            if (onAddStop != null)
              Padding(
                padding: EdgeInsets.only(
                  top: hasLifecycleActions ? AppTokens.spaceSm : 0,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: onAddStop,
                    icon: const Icon(Icons.add),
                    label: const Text('添加节点'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
