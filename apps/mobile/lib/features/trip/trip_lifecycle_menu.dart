import 'package:flutter/material.dart';

import 'trip_models.dart';

/// 行程级操作，作用于整份行程而非单个节点。
enum TripAction { changeTimezone, complete, cancel, delete }

class TripLifecycleMenu extends StatelessWidget {
  const TripLifecycleMenu({
    super.key,
    required this.plan,
    required this.onSelected,
  });

  final TripPlan plan;
  final ValueChanged<TripAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<TripAction>(
      tooltip: '行程操作',
      icon: const Icon(Icons.more_horiz),
      onSelected: onSelected,
      itemBuilder: (context) => [
        if (!plan.isReadOnly)
          const PopupMenuItem(
            value: TripAction.changeTimezone,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.public),
              title: Text('更改行程时区'),
            ),
          ),
        if (!plan.status.isTerminal) ...[
          const PopupMenuItem(
            value: TripAction.complete,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.check_circle_outline),
              title: Text('完成行程'),
            ),
          ),
          const PopupMenuItem(
            value: TripAction.cancel,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.event_busy_outlined),
              title: Text('取消行程'),
            ),
          ),
        ],
        const PopupMenuItem(
          value: TripAction.delete,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('删除行程'),
          ),
        ),
      ],
    );
  }
}

Future<bool> confirmCompleteTrip(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('完成这份行程？'),
      content: const Text('完成后行程将锁定为只读，节点无法再添加、编辑或删除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认完成'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<bool> confirmDeleteTrip(BuildContext context, String title) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除整份行程？'),
      content: Text('「$title」及其全部日期和节点将被级联清空，且无法撤销。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('永久删除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
