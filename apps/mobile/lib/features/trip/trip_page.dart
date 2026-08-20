import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

/// 行程页（P-TRIP）骨架。
///
/// 职责见文档页面清单：时间表与地图路线双视图、节点编辑、冲突提示。
/// 双视图依赖地图能力，当前仅保留页面位置，不放置模拟数据。
class TripPage extends StatelessWidget {
  const TripPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.route_outlined, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppTokens.spaceMd),
            Text('暂无行程', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '时间表与路线双视图待行程模块实现后接入。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
