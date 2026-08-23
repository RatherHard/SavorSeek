import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:savorseek/app/config/supabase_config.dart';

/// Supabase 客户端初始化状态。
///
/// 三态而非 bool：未配置与初始化失败的处置方式不同——前者需要补 dart-define，
/// 后者通常是地址不可达或参数非法，必须让用户看见区别而不是笼统报「不可用」。
enum SupabaseBootstrapStatus { ready, notConfigured, failed }

@immutable
class SupabaseBootstrapResult {
  const SupabaseBootstrapResult(this.status, {this.message});

  final SupabaseBootstrapStatus status;

  /// 非 ready 状态下面向用户的可见原因；ready 时为 null。
  final String? message;

  bool get isReady => status == SupabaseBootstrapStatus.ready;
}

/// 在 `runApp` 前初始化 Supabase 客户端。
///
/// 不抛异常：初始化失败不应让应用白屏，地图浏览等无需后端的能力仍应可用。
/// 失败原因通过返回值上抛，由外壳以可见提示呈现。
Future<SupabaseBootstrapResult> bootstrapSupabase() async {
  if (!SupabaseConfig.isConfigured) {
    return SupabaseBootstrapResult(
      SupabaseBootstrapStatus.notConfigured,
      message: SupabaseConfig.missingMessage,
    );
  }
  try {
    // supabase_flutter 2.17 起 anonKey 更名为 publishableKey，语义与取值不变；
    // 服务端 /opt/savorseek/.env 里的 ANON_KEY 直接填入即可。
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.anonKey,
    );
    return const SupabaseBootstrapResult(SupabaseBootstrapStatus.ready);
  } on Exception catch (error) {
    return SupabaseBootstrapResult(
      SupabaseBootstrapStatus.failed,
      message: '行程服务初始化失败：$error',
    );
  }
}
