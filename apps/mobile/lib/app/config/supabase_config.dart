import 'package:flutter/foundation.dart';

/// Public Supabase client configuration.
///
/// The anon key is not an authorization boundary; RLS and authenticated
/// sessions protect itinerary data. Never pass a service-role key here.
abstract final class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// 未配置时的提示。
  ///
  /// 刻意点明具体的注入命令而非只说「配置未完成」：这两个值由
  /// [String.fromEnvironment] 在编译期读取，Android 与 iOS 都没有原生兜底机制
  /// （与高德 Key 不同，后者由 Gradle 注入 manifest，任意启动方式均生效）。
  /// 因此漏加参数的启动一定落到此分支，而现象与「服务端故障」难以区分——
  /// 提示里必须带上排查线索。
  static String get missingMessage {
    const hint =
        '未注入 Supabase 连接参数。请在启动命令中附加 '
        '--dart-define-from-file=supabase.env'
        '（该文件由 supabase.env.example 复制而来）。';
    if (kIsWeb) {
      return '$hint 缺少 SUPABASE_URL 与 SUPABASE_ANON_KEY。';
    }
    return hint;
  }
}
