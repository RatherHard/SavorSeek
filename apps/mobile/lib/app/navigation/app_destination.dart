import 'package:flutter/material.dart';

/// 主导航目标。
///
/// `id` 对应 `docs/develop/1.前端基础结构开发.md` 与 `docs/product/用户流程.md`
/// 中的页面标识，作为页面、测试与文档之间的唯一锚点，不要改成本地化文案。
enum AppDestination {
  explore(
    id: 'P-MAP',
    label: '探索',
    icon: Icons.explore_outlined,
    selectedIcon: Icons.explore,
  ),
  trip(
    id: 'P-TRIP',
    label: '行程',
    icon: Icons.route_outlined,
    selectedIcon: Icons.route,
  ),
  mine(
    id: 'P-MINE',
    label: '我的',
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
  );

  const AppDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  /// 页面标识，例如 `P-MAP`。
  final String id;

  /// 导航栏展示的中文标签。
  final String label;

  /// 未选中态图标。
  final IconData icon;

  /// 选中态图标。
  final IconData selectedIcon;
}
