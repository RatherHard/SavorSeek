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
            onMenuAction: onStopAction == null || isSelecting
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
    this.onMenuAction,
  });

  final TripStop stop;
  final bool isLast;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<StopAction>? onMenuAction;

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
              onMenuAction: onMenuAction,
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
    this.onMenuAction,
  });

  final TripStop stop;

  final bool isSelected;
  final bool isSelecting;

  /// 为空时卡片不可点：终态项与无写入能力时不该给出可点的错觉。
  final VoidCallback? onTap;

  /// 长按进入多选态。
  final VoidCallback? onLongPress;

  /// 操作菜单回调。为空时不显示菜单。
  final ValueChanged<StopAction>? onMenuAction;

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
                  if (onMenuAction != null) ...[
                    const SizedBox(width: AppTokens.spaceXs),
                    _StopMenu(stop: stop, onSelected: onMenuAction!),
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

/// 行程项的操作菜单。
///
/// 按状态给出不同选项而非全部列出后禁用：终态项的「改期」永远不可用，列出来
/// 只会让用户反复尝试。
class _StopMenu extends StatelessWidget {
  const _StopMenu({required this.stop, required this.onSelected});

  final TripStop stop;
  final ValueChanged<StopAction> onSelected;

  @override
  Widget build(BuildContext context) {
    // 已完成 / 已跳过的项是历史事实，库端拒绝任何变更，故不给菜单。
    if (stop.status == TripItemStatus.completed ||
        stop.status == TripItemStatus.skipped) {
      return const SizedBox.shrink();
    }

    return PopupMenuButton<StopAction>(
      onSelected: onSelected,
      tooltip: '行程项操作',
      icon: const Icon(Icons.more_vert, size: 18),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: StopAction.edit,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('编辑'),
            subtitle: Text('改名称、备注与排期'),
          ),
        ),
        const PopupMenuItem(
          value: StopAction.delete,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('删除'),
            subtitle: Text('不可恢复'),
          ),
        ),
      ],
    );
  }
}
