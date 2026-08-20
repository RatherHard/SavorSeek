import 'package:flutter/material.dart';

import 'package:savorseek/app/navigation/app_shell.dart';
import 'package:savorseek/app/theme/app_theme.dart';

/// 应用根组件。
class SavorSeekApp extends StatelessWidget {
  const SavorSeekApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SavorSeek',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const AppShell(),
    );
  }
}
