import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_controller.dart';
import 'trip_models.dart';
import 'trip_repository.dart';

class TripPage extends StatefulWidget {
  const TripPage({super.key, this.repository = const SupabaseTripRepository()});

  final TripRepository repository;

  @override
  State<TripPage> createState() => _TripPageState();
}

class _TripPageState extends State<TripPage> {
  late final TripController _controller = TripController(widget.repository);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onStateChanged);
    _controller.load();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onStateChanged)
      ..dispose();
    super.dispose();
  }

  void _onStateChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppTokens.durationNormal,
      child: switch (_controller.state) {
        TripLoading() => const _TripLoading(key: ValueKey('loading')),
        TripEmpty() => _TripEmpty(
          key: const ValueKey('empty'),
          onCreateTrip: () {},
        ),
        TripError(:final message) => _TripError(
          key: const ValueKey('error'),
          message: message,
          onRetry: _controller.load,
        ),
        TripLoaded(:final plan) => _TripLoaded(
          key: const ValueKey('loaded'),
          plan: plan,
        ),
      },
    );
  }
}

class _TripLoading extends StatelessWidget {
  const _TripLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: key,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: [
        _LoadingBlock(
          height: 112,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        const SizedBox(height: AppTokens.spaceMd),
        ...List.generate(
          4,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: _LoadingBlock(
              height: 88,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
    );
  }
}

class _TripEmpty extends StatelessWidget {
  const _TripEmpty({super.key, required this.onCreateTrip});

  final VoidCallback onCreateTrip;

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
                  Icons.route_outlined,
                  size: 40,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text('暂无行程', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '把想去的美食地点交给 Agent，\n从一顿饭开始安排你的下一段旅程。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: onCreateTrip,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('规划一段美食行程'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripError extends StatelessWidget {
  const _TripError({super.key, required this.message, required this.onRetry});

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

class _TripLoaded extends StatelessWidget {
  const _TripLoaded({super.key, required this.plan});

  final TripPlan plan;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: key,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceMd,
            AppTokens.spaceMd,
            AppTokens.spaceSm,
          ),
          sliver: SliverToBoxAdapter(child: _TripHeader(plan: plan)),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
          sliver: SliverToBoxAdapter(child: _MapFallback(state: plan.mapState)),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceLg,
            AppTokens.spaceMd,
            AppTokens.spaceXl,
          ),
          sliver: SliverList.builder(
            itemCount: plan.days.length,
            itemBuilder: (context, index) =>
                _TripDayTimeline(day: plan.days[index]),
          ),
        ),
      ],
    );
  }
}

class _TripHeader extends StatelessWidget {
  const _TripHeader({required this.plan});

  final TripPlan plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '我的行程',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: scheme.primary),
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                plan.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                plan.destination,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '更多行程操作',
          onPressed: () {},
          icon: const Icon(Icons.more_horiz),
        ),
      ],
    );
  }
}

class _MapFallback extends StatelessWidget {
  const _MapFallback({required this.state});

  final TripMapState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUnavailable = state == TripMapState.unavailable;
    return Container(
      height: 156,
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
                    isUnavailable ? Icons.map_outlined : Icons.map,
                    color: scheme.primary,
                    size: 30,
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    isUnavailable ? '地图路线暂不可用' : '路线地图',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTokens.spaceXs),
                  Text(
                    isUnavailable ? '时间表仍可正常查看，地图接入后会显示路线。' : '查看地点之间的移动顺序与距离。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
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

class _TripDayTimeline extends StatelessWidget {
  const _TripDayTimeline({required this.day});

  final TripDay day;

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
          ),
        ),
      ],
    );
  }
}

class _TimelineStop extends StatelessWidget {
  const _TimelineStop({required this.stop, required this.isLast});

  final TripStop stop;
  final bool isLast;

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
          Expanded(child: _StopCard(stop: stop)),
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
  const _StopCard({required this.stop});

  final TripStop stop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    stop.title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (stop.isLocked)
                  Icon(Icons.lock_outline, size: 17, color: scheme.primary),
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
    );
  }
}
