import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';

/// 我的页（P-MINE）骨架。
///
/// 职责见文档页面清单：偏好分析、收藏的地点、账号管理、设置。
/// 其中「账号管理」已接入 Supabase Auth；其余三项依赖记忆模块，仍为占位，
/// 不放置任何模拟的偏好或收藏数据。
class MinePage extends StatefulWidget {
  const MinePage({super.key, this.auth});

  /// 认证服务。为空时账号管理分区保持禁用。
  final AuthService? auth;

  /// 页面职责分区，顺序与文档页面清单一致。
  static const List<({IconData icon, String label})> sections = [
    (icon: Icons.insights_outlined, label: '偏好分析'),
    (icon: Icons.bookmark_outline, label: '收藏的地点'),
    (icon: Icons.account_circle_outlined, label: '账号管理'),
    (icon: Icons.settings_outlined, label: '设置'),
  ];

  static const String accountLabel = '账号管理';

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  StreamSubscription<String?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    // 会话可能由其他页面（行程页登录引导）改变，订阅后本页无需手动刷新。
    _authSubscription = widget.auth?.userIdChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleAccountTap() async {
    final auth = widget.auth;
    if (auth == null) return;
    if (auth.isSignedIn) {
      await auth.signOut();
    } else {
      await showAuthSheet(context, auth: auth);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = widget.auth;

    return ListView.separated(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      itemCount: MinePage.sections.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppTokens.spaceSm),
      itemBuilder: (context, index) {
        final section = MinePage.sections[index];
        final isAccount = section.label == MinePage.accountLabel;
        final isEnabled = isAccount && auth != null;
        // 用 Material 而非 Container 承载底色：ListTile 的水波纹绘制在最近的
        // Material 上，若底色来自外层 DecoratedBox，点击反馈会被完全遮住。
        return Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(section.icon, color: scheme.onSurfaceVariant),
            title: Text(section.label),
            subtitle: Text(_subtitleFor(isAccount: isAccount, auth: auth)),
            trailing: isEnabled
                ? Icon(
                    auth.isSignedIn ? Icons.logout : Icons.login,
                    color: scheme.primary,
                  )
                : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            onTap: isEnabled ? _handleAccountTap : null,
            // 其余功能尚未实现，显式禁用而不是给一个无反馈的可点项。
            enabled: isEnabled,
          ),
        );
      },
    );
  }

  String _subtitleFor({required bool isAccount, required AuthService? auth}) {
    if (!isAccount) return '待实现';
    if (auth == null) return '账号服务尚未就绪';
    if (!auth.isSignedIn) return '未登录 · 点击登录或注册';
    return auth.currentEmail ?? '已登录';
  }
}
