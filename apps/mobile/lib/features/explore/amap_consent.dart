import 'package:flutter/material.dart';

/// 高德 SDK 合规声明状态。
///
/// 高德要求宿主应用在初始化前告知用户其隐私政策并取得同意，插件的
/// `hasContains` / `hasShow` / `hasAgree` 三个标记即对应该要求。三者任一为
/// false 都会导致地图白屏，但它们表达的是「事实」而非开关——把它们硬编码为
/// true 等于在未向用户披露的情况下声称已获同意，因此这里用真实的同意状态驱动。
///
/// 当前为内存态：未接入持久化，每次启动都会重新询问。同意记录的最终归属是
/// Supabase 侧的用户数据，待账户体系落地后迁移。
class AmapConsent extends ChangeNotifier {
  bool _agreed = false;

  /// 用户是否已阅读并同意高德隐私政策。
  bool get agreed => _agreed;

  void agree() {
    if (_agreed) return;
    _agreed = true;
    notifyListeners();
  }
}

/// 高德隐私政策告知卡片。
///
/// 在用户同意前占据地图区域，避免展示一张无法解释的白屏。
class AmapConsentNotice extends StatelessWidget {
  const AmapConsentNotice({super.key, required this.onAgree});

  final VoidCallback onAgree;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.privacy_tip_outlined,
                  color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('地图服务说明', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '本应用使用高德地图 SDK 展示地图。加载地图时，高德会获取设备网络信息与'
                '大致位置以完成瓦片加载与鉴权。同意后方可显示地图。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onAgree,
                child: const Text('同意并显示地图'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
