import 'package:flutter/material.dart';

import 'package:savorseek/app/app.dart';
import 'package:savorseek/app/app_dependencies.dart';
import 'package:savorseek/app/supabase/supabase_bootstrap.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

Future<void> main() async {
  // Supabase 初始化依赖平台通道（会话持久化走 SharedPreferences），
  // 必须先确保 binding 就绪。
  WidgetsFlutterBinding.ensureInitialized();
  // 时区数据必须在首次渲染行程前加载：行程项时间一律按行程时区折算，未加载时
  // 换算会抛错。纯内存操作，无需 await。
  TripTimeZone.ensureInitialized();
  final bootstrap = await bootstrapSupabase();
  runApp(SavorSeekApp(dependencies: AppDependencies.fromBootstrap(bootstrap)));
}
