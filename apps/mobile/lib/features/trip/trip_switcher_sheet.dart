import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_repository.dart';

/// 行程切换器的选择结果。
sealed class TripSwitcherResult {
  const TripSwitcherResult();
}

/// 切换到指定行程。
final class TripSwitcherSelected extends TripSwitcherResult {
  const TripSwitcherSelected(this.tripId);

  final String tripId;
}

/// 新建行程。
final class TripSwitcherCreate extends TripSwitcherResult {
  const TripSwitcherCreate();
}

/// 弹出行程切换器。用户取消时返回 null。
///
/// 用 sealed 结果而非两个回调：切换与新建互斥，调用方必须处理且只处理其中一种，
/// 用 switch 可由编译器保证不漏分支。
Future<TripSwitcherResult?> showTripSwitcherSheet(
  BuildContext context, {
  required List<TripSummary> trips,
  required String currentTripId,
  bool canCreate = true,
}) {
  return showModalBottomSheet<TripSwitcherResult>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TripSwitcherSheet(
      trips: trips,
      currentTripId: currentTripId,
      canCreate: canCreate,
    ),
  );
}

class _TripSwitcherSheet extends StatelessWidget {
  const _TripSwitcherSheet({
    required this.trips,
    required this.currentTripId,
    required this.canCreate,
  });

  final List<TripSummary> trips;
  final String currentTripId;
  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceLg,
              AppTokens.spaceLg,
              AppTokens.spaceSm,
            ),
            child: Text('切换行程', style: theme.textTheme.titleLarge),
          ),
          // 行程数可能很多，限高后内部滚动，避免整个面板顶到屏幕外。
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: trips.length,
              itemBuilder: (context, index) {
                final trip = trips[index];
                final isCurrent = trip.id == currentTripId;
                return ListTile(
                  leading: Icon(
                    isCurrent ? Icons.check_circle : Icons.map_outlined,
                    color: isCurrent ? theme.colorScheme.primary : null,
                  ),
                  title: Text(trip.title),
                  subtitle: Text(_rangeLabel(trip)),
                  // 当前行程不可再选：点了没有任何变化，禁用比无反应更诚实。
                  onTap: isCurrent
                      ? null
                      : () =>
                            Navigator.of(context)
                                .pop(TripSwitcherSelected(trip.id)),
                );
              },
            ),
          ),
          if (canCreate) ...[
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.add, color: theme.colorScheme.primary),
              title: Text(
                '新建行程',
                style: TextStyle(color: theme.colorScheme.primary),
              ),
              onTap: () =>
                  Navigator.of(context).pop(const TripSwitcherCreate()),
            ),
          ],
          const SizedBox(height: AppTokens.spaceSm),
        ],
      ),
    );
  }

  /// 「2026-09-01 起 3 天」或当天往返。
  static String _rangeLabel(TripSummary trip) {
    final start =
        '${trip.startDate.year}-'
        '${_two(trip.startDate.month)}-${_two(trip.startDate.day)}';
    final days = trip.dayCount;
    if (days <= 1) return '$start（当天往返）';
    return '$start 起 $days 天';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
