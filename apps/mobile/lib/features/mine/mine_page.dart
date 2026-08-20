import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

/// 我的页（P-MINE）骨架。
///
/// 职责见文档页面清单：偏好分析、收藏的地点、账号管理、设置。
/// 四个分区依赖 Supabase Auth 与记忆模块，当前仅列出入口占位，
/// 不放置任何模拟的偏好或收藏数据。
class MinePage extends StatelessWidget {
  const MinePage({super.key});

  /// 页面职责分区，顺序与文档页面清单一致。
  static const List<({IconData icon, String label})> sections = [
    (icon: Icons.insights_outlined, label: '偏好分析'),
    (icon: Icons.bookmark_outline, label: '收藏的地点'),
    (icon: Icons.account_circle_outlined, label: '账号管理'),
    (icon: Icons.settings_outlined, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView.separated(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      itemCount: sections.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppTokens.spaceSm),
      itemBuilder: (context, index) {
        final section = sections[index];
        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
          child: ListTile(
            leading: Icon(section.icon, color: scheme.onSurfaceVariant),
            title: Text(section.label),
            subtitle: const Text('待实现'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            // 功能尚未实现，显式禁用而不是给一个无反馈的可点项。
            enabled: false,
          ),
        );
      },
    );
  }
}
