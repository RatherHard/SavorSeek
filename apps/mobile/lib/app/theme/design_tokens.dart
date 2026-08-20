import 'package:flutter/material.dart';

/// 全局设计令牌。
///
/// 所有间距、圆角、动效时长与品牌色都集中在此处定义，页面与组件不得内联
/// 魔法数值，避免同一视觉语言在多处漂移。
abstract final class AppTokens {
  // 品牌色：以温暖的赤陶色作为种子色，呼应「美食旅行」的主题，
  // 避免默认紫色带来的模板观感。
  static const Color seed = Color(0xFFC2410C);
  static const Color accent = Color(0xFFF59E0B);

  // 间距阶梯（4 的倍数）。
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 16;
  static const double spaceLg = 24;
  static const double spaceXl = 32;

  // 圆角：导航胶囊使用 full，卡片使用 md。
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusFull = 999;

  // 动效时长。
  static const Duration durationFast = Duration(milliseconds: 150);
  static const Duration durationNormal = Duration(milliseconds: 250);

  /// 主导航胶囊的高度。
  static const double navBarHeight = 44;
}
