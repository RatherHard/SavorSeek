import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'place_models.dart';

/// 地点详情面板。
///
/// 展示名称、类别、地址与信息时效，并提供「加入行程」入口。时效不是装饰性信息：
/// PRD 的可解释性要求推荐与地点信息必须让用户知道数据何时抓取，否则用户无从判断
/// 营业状态、价格等易变字段是否可信。
class PlaceDetailSheet extends StatelessWidget {
  const PlaceDetailSheet({
    super.key,
    required this.place,
    required this.onClose,
    this.onAddToTrip,
    this.isAdding = false,
  });

  final Place place;
  final VoidCallback onClose;

  /// 为空时「加入行程」按钮禁用（例如未登录）。
  final Future<void> Function()? onAddToTrip;

  /// 写入进行中。此时按钮显示进度并阻止重复提交。
  final bool isAdding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final category = place.primaryCategory;
    final addToTrip = onAddToTrip;

    return Material(
      color: scheme.surface,
      elevation: 12,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusMd),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      place.name,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
              if (category != null) ...[
                const SizedBox(height: AppTokens.spaceXs),
                _CategoryChip(label: category),
              ],
              if (place.address != null) ...[
                const SizedBox(height: AppTokens.spaceMd),
                _DetailRow(icon: Icons.place_outlined, text: place.address!),
              ],
              const SizedBox(height: AppTokens.spaceSm),
              _DetailRow(
                icon: Icons.schedule_outlined,
                text: '信息更新于${formatFreshness(place.fetchedAt)}',
                isSubtle: true,
              ),
              const SizedBox(height: AppTokens.spaceLg),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: isAdding || addToTrip == null
                      ? null
                      : () => addToTrip(),
                  icon: isAdding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_location_alt_outlined),
                  label: Text(isAdding ? '正在加入…' : '加入行程'),
                ),
              ),
              if (addToTrip == null) ...[
                const SizedBox(height: AppTokens.spaceSm),
                Text(
                  '登录后即可把地点加入行程。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 把抓取时间表述为相对时效。
///
/// 用相对表述而非绝对时间戳：用户关心的是「这条信息有多旧」，而不是具体日期。
/// 超过 30 天则退回绝对日期——「45 天前」远不如「2026-07-09」易于判断。
String formatFreshness(DateTime fetchedAt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final elapsed = reference.difference(fetchedAt);

  if (elapsed.isNegative || elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} 分钟前';
  if (elapsed.inHours < 24) return '${elapsed.inHours} 小时前';
  if (elapsed.inDays <= 30) return '${elapsed.inDays} 天前';

  final month = fetchedAt.month.toString().padLeft(2, '0');
  final day = fetchedAt.day.toString().padLeft(2, '0');
  return '${fetchedAt.year}-$month-$day';
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.text,
    this.isSubtle = false,
  });

  final IconData icon;
  final String text;
  final bool isSubtle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final style = isSubtle
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyMedium;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppTokens.spaceSm),
        Expanded(
          child: Text(
            text,
            style: style?.copyWith(color: color, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
