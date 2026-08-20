import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

/// 应用主题。
///
/// 亮色与暗色都显式构建，不依赖框架默认值，确保两种模式下的对比度与
/// 层次都是有意为之的结果。
abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppTokens.seed,
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
      // 键盘与读屏焦点必须可见，不依赖颜色单一通道传达状态。
      focusColor: scheme.primary.withValues(alpha: 0.12),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
