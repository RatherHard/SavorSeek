import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_models.dart';

/// 行程一级与二级页面共用的状态视图。
///
/// 单独成文件而非各页自带一份：加载骨架、错误页与登录引导在两级页面中呈现完全
/// 相同，复制两份必然随时间漂移成两种文案。同时把详情页压到 800 行以内。

/// 骨架屏中的一块占位。
class TripLoadingBlock extends StatelessWidget {
  const TripLoadingBlock({super.key, required this.height, this.color});

  final double height;

  /// 为空时取主题的 surfaceContainerHighest。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = color ?? Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
    );
  }
}

/// 读取失败，可重试。
class TripErrorView extends StatelessWidget {
  const TripErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, size: 44, color: scheme.error),
            const SizedBox(height: AppTokens.spaceMd),
            Text('行程暂时加载失败', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '请检查网络后重试。\n$message',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未认证态：RLS 下读取恒为空，这不是错误，因此单独呈现为登录引导。
class TripSignInPromptView extends StatelessWidget {
  const TripSignInPromptView({
    super.key,
    required this.message,
    required this.onSignIn,
  });

  final String message;

  /// 为空时按钮禁用：未注入认证服务时点了没有任何反馈。
  final Future<void> Function()? onSignIn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                child: Icon(
                  Icons.lock_person_outlined,
                  size: 40,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text('登录后查看行程', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: onSignIn,
              icon: const Icon(Icons.login),
              label: const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 行程已不存在。
///
/// 与「暂无行程」区别对待：详情页只服务一个已知 id，读不到只可能是它没了
/// （另一台设备删的，或列表数据已过期），显示「暂无行程」是误导。
class TripDetailGoneView extends StatelessWidget {
  const TripDetailGoneView({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.link_off_outlined,
              size: 44,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Text('此行程已不存在', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '它可能已在其他设备上被删除。\n返回列表可以看到最新的行程。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回列表'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 无法呈现地图时的占位图。
///
/// 说明为何没有地图，并给出补齐的办法。此前文案是「地图接入后会显示路线」，
/// 暗示地图能力尚未开发；真实原因是这份行程里还没有任何带坐标的地点节点，
/// 两者要用户做的事完全不同。
class TripMapFallback extends StatelessWidget {
  const TripMapFallback({super.key, required this.state, this.onAddPlace});

  final TripMapState state;

  /// 添加地点节点。为空时只说明原因不给按钮——点了没反应比没有按钮更糟。
  final VoidCallback? onAddPlace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUnavailable = state == TripMapState.unavailable;
    final showAction = isUnavailable && onAddPlace != null;
    return Container(
      // 多出按钮就要多给高度：固定 156 时按钮会把内容挤出 10px 而溢出。
      height: showAction ? 188 : 156,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _MapPatternPainter(color: scheme.outlineVariant),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isUnavailable ? Icons.add_location_alt_outlined : Icons.map,
                    color: scheme.primary,
                    size: 28,
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    isUnavailable ? '还没有地点节点' : '路线地图',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTokens.spaceXs),
                  Text(
                    isUnavailable
                        ? '自由安排节点没有位置信息，加入一家店即可在地图上看到它。'
                        : '查看地点之间的移动顺序与距离。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (showAction)
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.spaceSm),
                      child: FilledButton.tonalIcon(
                        onPressed: onAddPlace,
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('添加地点'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPatternPainter extends CustomPainter {
  const _MapPatternPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 36) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MapPatternPainter oldDelegate) =>
      oldDelegate.color != color;
}
