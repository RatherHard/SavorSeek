import 'package:flutter/material.dart';

import 'package:savorseek/app/config/amap_config.dart';
import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/explore/amap_surface.dart';

/// 探索页（P-MAP）。
///
/// 布局约束来自 `docs/develop/1.前端基础结构开发.md`：地图占据除底部
/// Agent 指令栏外的全部可用空间，指令栏固定在底部不随地图消失。
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final AmapConsent _consent = AmapConsent();

  @override
  void initState() {
    super.initState();
    _consent.addListener(_onConsentChanged);
  }

  void _onConsentChanged() => setState(() {});

  @override
  void dispose() {
    _consent.removeListener(_onConsentChanged);
    _consent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Expanded 使地图吃掉除指令栏外的全部高度。
        Expanded(child: _buildMapArea()),
        // 指令栏不参与地图区域的尺寸计算，始终贴底。
        const AgentCommandBar(),
      ],
    );
  }

  Widget _buildMapArea() {
    // iOS 的 Key 只能经 Dart 注入，缺失时显式说明，避免白屏无法区分
    // 「未配置」「鉴权失败」「网络异常」三种原因。
    // Android 的 Key 在构建期注入 manifest，由 Gradle 侧校验，此处恒为 false。
    if (AmapConfig.isKeyMissing) {
      return const _MapUnavailableNotice(
        message: '未配置 iOS 端高德地图 Key，地图无法显示。\n'
            '请在 amap.env 中填入 AMAP_IOS_KEY，'
            '并在构建时附加 --dart-define-from-file=amap.env。',
      );
    }

    if (!_consent.agreed) {
      return AmapConsentNotice(onAgree: _consent.agree);
    }

    return const AmapSurface();
  }
}

class _MapUnavailableNotice extends StatelessWidget {
  const _MapUnavailableNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map_outlined,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('地图不可用', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
