import 'package:flutter/material.dart';

import 'package:savorseek/app/app.dart';
import 'package:savorseek/app/app_dependencies.dart';
import 'package:savorseek/app/supabase/supabase_bootstrap.dart';

Future<void> main() async {
  // Supabase 初始化依赖平台通道（会话持久化走 SharedPreferences），
  // 必须先确保 binding 就绪。
  WidgetsFlutterBinding.ensureInitialized();
  final bootstrap = await bootstrapSupabase();
  runApp(SavorSeekApp(dependencies: AppDependencies.fromBootstrap(bootstrap)));
}
