import 'package:flutter/material.dart';

import 'package:savorseek/app/app_dependencies.dart';
import 'package:savorseek/app/navigation/app_shell.dart';
import 'package:savorseek/app/theme/app_theme.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/trip/trip_repository_fakes.dart';

/// 应用根组件。
class SavorSeekApp extends StatelessWidget {
  const SavorSeekApp({super.key, this.dependencies});

  /// 应用级依赖。为空时退化为「后端未配置」形态，便于纯 UI 测试直接构造。
  final AppDependencies? dependencies;

  static const AppDependencies _offlineFallback = AppDependencies(
    auth: UnavailableAuthService(),
    tripRepository: UnavailableTripRepository(),
    favoriteRepository: UnavailableFavoriteRepository(),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SavorSeek',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: AppShell(dependencies: dependencies ?? _offlineFallback),
    );
  }
}
