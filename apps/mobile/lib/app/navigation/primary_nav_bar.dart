import 'package:flutter/material.dart';

import 'package:savorseek/app/navigation/app_destination.dart';
import 'package:savorseek/app/theme/design_tokens.dart';

/// 顶部主导航。
///
/// 采用胶囊分段样式而非默认 TabBar，避免模板观感；选中态同时通过
/// 填充色、图标实心化与字重三个通道传达，不单独依赖颜色（NFR-303）。
class PrimaryNavBar extends StatelessWidget {
  const PrimaryNavBar({
    super.key,
    required this.current,
    required this.onSelected,
  });

  /// 当前选中的目标。
  final AppDestination current;

  /// 选中回调；重复点击当前项也会触发，由调用方决定是否忽略。
  final ValueChanged<AppDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      container: true,
      label: '主导航',
      child: Container(
        height: AppTokens.navBarHeight,
        padding: const EdgeInsets.all(AppTokens.spaceXs),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        ),
        child: Row(
          children: [
            for (final destination in AppDestination.values)
              Expanded(
                child: _NavSegment(
                  destination: destination,
                  isSelected: destination == current,
                  onTap: () => onSelected(destination),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavSegment extends StatelessWidget {
  const _NavSegment({
    required this.destination,
    required this.isSelected,
    required this.onTap,
  });

  final AppDestination destination;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = isSelected ? scheme.onPrimary : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: isSelected,
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: AnimatedContainer(
          duration: AppTokens.durationFast,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: isSelected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isSelected ? destination.selectedIcon : destination.icon,
                size: 18,
                color: foreground,
              ),
              const SizedBox(width: AppTokens.spaceXs),
              Text(
                destination.label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
