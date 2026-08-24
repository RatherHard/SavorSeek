import 'package:flutter/material.dart';

import 'package:savorseek/app/app_dependencies.dart';
import 'package:savorseek/app/navigation/app_destination.dart';
import 'package:savorseek/app/navigation/primary_nav_bar.dart';
import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/explore_page.dart';
import 'package:savorseek/features/mine/mine_page.dart';
import 'package:savorseek/features/trip/trip_list_page.dart';

/// 应用外壳：承载顶部主导航与三个主页面。
///
/// 主导航在全局范围内保持一致，用户可在三页之间自由切换。使用
/// [IndexedStack] 而非条件构建，使离开的页面保持状态（地图视野、滚动位置
/// 与执行中的 Agent 任务不因切页而丢失，对应用户流程的导航约束第 2 条）。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.initialDestination = AppDestination.explore,
    required this.dependencies,
  });

  /// 初始页面，默认为探索页（文档：登录成功后 P-MAP 为默认首页）。
  final AppDestination initialDestination;

  final AppDependencies dependencies;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late AppDestination _current = widget.initialDestination;

  void _select(AppDestination destination) {
    if (destination == _current) return;
    setState(() => _current = destination);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: PrimaryNavBar(current: _current, onSelected: _select),
        titleSpacing: AppTokens.spaceMd,
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: AppDestination.values.indexOf(_current),
          sizing: StackFit.expand,
          children: [
            ExplorePage(
              placeRepository: widget.dependencies.placeRepository,
              scheduler: widget.dependencies.scheduler,
              consent: widget.dependencies.mapConsent,
            ),
            TripListPage(
              repository: widget.dependencies.tripRepository,
              auth: widget.dependencies.auth,
              mapConsent: widget.dependencies.mapConsent,
              routeService: widget.dependencies.routeService,
              placeRepository: widget.dependencies.placeRepository,
            ),
            MinePage(auth: widget.dependencies.auth),
          ],
        ),
      ),
    );
  }
}
