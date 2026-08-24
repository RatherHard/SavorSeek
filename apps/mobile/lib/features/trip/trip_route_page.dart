import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/amap_consent.dart';

import 'trip_mapper.dart';
import 'trip_models.dart';
import 'trip_route_map.dart';
import 'trip_route_service.dart';

/// 全屏路线视图。
///
/// 小地图为了不与页面滚动争夺纵向手势而关闭了交互，缩放与平移在此提供。
/// 底部并列节点顺序表：地图给空间关系，列表给时间顺序，两者缺一都读不出行程。
class TripRoutePage extends StatelessWidget {
  const TripRoutePage({
    super.key,
    required this.plan,
    required this.consent,
    this.routeService,
  });

  final TripPlan plan;
  final AmapConsent consent;
  final TripRouteService? routeService;

  @override
  Widget build(BuildContext context) {
    final stops = plan.routeStops;

    return Scaffold(
      appBar: AppBar(title: Text('${plan.title} · 路线')),
      body: Column(
        children: [
          Expanded(
            child: TripRouteMap(
              plan: plan,
              consent: consent,
              routeService: routeService,
              // 全屏视图放开手势：此处没有与之竞争的滚动容器。
              interactive: true,
              height: double.infinity,
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              itemCount: stops.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppTokens.spaceSm),
              itemBuilder: (context, index) =>
                  _RouteStopCard(index: index, stop: stops[index]),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顺序表里的一个节点。编号与地图上的标记一致。
class _RouteStopCard extends StatelessWidget {
  const _RouteStopCard({required this.index, required this.stop});

  final int index;
  final TripStop stop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      width: 176,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 编号与地图标记对应，用户据此把卡片与图上的点对上。
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              Text(
                TripMapper.slotLabel(stop.type),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            stop.title,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const Spacer(),
          Text(
            stop.subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
