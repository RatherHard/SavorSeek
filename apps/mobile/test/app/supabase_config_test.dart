import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/app/config/supabase_config.dart';

void main() {
  test('未注入 dart-define 时给出可操作的排查提示', () {
    // 复现「未注入 Supabase 连接参数」的成因：String.fromEnvironment 是编译期
    // 读取，没有运行期兜底，任何未附加 --dart-define-from-file=supabase.env
    // 的启动都会落到此分支。flutter test 默认不注入，故此处即为该场景。
    if (SupabaseConfig.isConfigured) {
      // 若 CI 或本地显式注入了参数，退化为校验注入结果自洽。
      expect(SupabaseConfig.url, isNotEmpty);
      expect(SupabaseConfig.anonKey, isNotEmpty);
      return;
    }

    expect(SupabaseConfig.url, isEmpty);
    expect(SupabaseConfig.anonKey, isEmpty);
    // 提示必须点明注入方式与文件名，否则现象与服务端故障无法区分。
    expect(SupabaseConfig.missingMessage, contains('--dart-define-from-file'));
    expect(SupabaseConfig.missingMessage, contains('supabase.env'));
  });
}
