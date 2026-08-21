import 'package:flutter/foundation.dart';

/// Public Supabase client configuration.
///
/// The anon key is not an authorization boundary; RLS and authenticated
/// sessions protect itinerary data. Never pass a service-role key here.
abstract final class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  static String get missingMessage {
    if (kIsWeb) {
      return '未配置 Supabase 客户端参数。请通过 dart-define 注入 SUPABASE_URL '
          '和 SUPABASE_ANON_KEY。';
    }
    return '尚未连接行程服务，请完成 Supabase 配置后重试。';
  }
}
