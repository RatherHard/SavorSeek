import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_models.dart';

/// 行程项可执行的操作。
enum StopAction { edit, delete }

/// 一天的时间轴。
///
/// 与详情页分文件：时间轴这一组 widget（含卡片与菜单）约 330 行，与页面骨架同处
/// 一个文件会超过项目规范的 800 行上限。
class TripDayTimeline extends StatelessWidget {
  const TripDayTimeline({
    super.key,
    required this.day,
    this.onStopAction,
    this.selectedStopIds = const {},
    this.onToggleSelection,
    this.isSelecting = false,
  });

  final TripDay day;

  /// 行程项操作回调。为空时不给出任何操作入口（无写入能力的仓库）。
  final void Function(TripDay day, TripStop stop, StopAction action)?
  onStopAction;

  final Set<String> selectedStopIds;
  final ValueChanged<TripStop>? onToggleSelection;
  final bool isSelecting;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(day.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceMd),
        ...day.stops.asMap().entries.map(
          (entry) => _TimelineStop(
            stop: entry.value,
            isLast: entry.key == day.stops.length - 1,
            isSelected: selectedStopIds.contains(entry.value.id),
            isSelecting: isSelecting,
            // 多选态下点击即切换选中；否则点卡片改期，是最常用的操作。
            onTap: isSelecting
                ? (onToggleSelection == null
                      ? null
                      : () => onToggleSelection!(entry.value))
                : (onStopAction == null || !entry.value.canReschedule
                      ? null
                      : () => onStopAction!(day, entry.value, StopAction.edit)),
            // 长按进入多选：这是列表多选的通用手势，不必额外给一个「选择」按钮。
            onLongPress: onToggleSelection == null
                ? null
                : () => onToggleSelection!(entry.value),
            onAction: onStopAction == null || isSelecting
                ? null
                : (action) => onStopAction!(day, entry.value, action),
          ),
        ),
      ],
    );
  }
}

class _TimelineStop extends StatelessWidget {
  const _TimelineStop({
    required this.stop,
    required this.isLast,
    this.isSelected = false,
    this.isSelecting = false,
    this.onTap,
    this.onLongPress,
    this.onAction,
  });

  final TripStop stop;
  final bool isLast;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<StopAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 58,
            child: Column(
              children: [
                Text(
                  _formatTime(stop.startAt),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: AppTokens.spaceSm),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!isLast)
            VerticalDivider(
              width: AppTokens.spaceMd,
              thickness: 1,
              color: scheme.outlineVariant,
            )
          else
            const SizedBox(width: AppTokens.spaceMd),
          Expanded(
            child: _StopCard(
              stop: stop,
              isSelected: isSelected,
              isSelecting: isSelecting,
              onTap: onTap,
              onLongPress: onLongPress,
              onAction: onAction,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _StopCard extends StatelessWidget {
  const _StopCard({
    required this.stop,
    this.isSelected = false,
    this.isSelecting = false,
    this.onTap,
    this.onLongPress,
    this.onAction,
  });

  final TripStop stop;

  final bool isSelected;
  final bool isSelecting;

  /// 为空时卡片不可点：终态项与无写入能力时不该给出可点的错觉。
  final VoidCallback? onTap;

  /// 长按进入多选态。
  final VoidCallback? onLongPress;

  /// 操作菜单回调。为空时不显示菜单。
  final ValueChanged<StopAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      elevation: 0,
      // 选中态用主色容器着色：多选时需要一眼看出选了哪几张。
      color: isSelected
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        side: isSelected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        // InkWell 包在 Padding 外层：涟漪应覆盖整张卡片，包在内层只有文字区域响应。
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isSelecting) ...[
                    Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: isSelected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                  ],
                  Expanded(
                    child: Text(
                      stop.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (stop.isLocked)
                    Icon(Icons.lock_outline, size: 17, color: scheme.primary),
                  if (onAction != null &&
                      !isSelecting &&
                      !stop.status.isTerminal) ...[
                    const SizedBox(width: AppTokens.spaceXs),
                    IconButton(
                      tooltip: '删除节点',
                      onPressed: () => onAction!(StopAction.delete),
                      style: IconButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                stop.subtitle,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (stop.note case final note?) ...[
                const SizedBox(height: AppTokens.spaceSm),
                Text(
                  note,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
