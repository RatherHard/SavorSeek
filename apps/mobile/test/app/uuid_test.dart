import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/app/util/uuid.dart';

void main() {
  test('生成的字符串符合 v4 UUID 形态', () {
    // 幂等键的列类型是 uuid，形态不合会在服务端被拒。
    final pattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    for (var i = 0; i < 64; i++) {
      expect(generateUuidV4(), matches(pattern));
    }
  });

  test('连续生成不重复', () {
    // 重复的幂等键会让第二次写入命中缓存结果，静默丢掉本次请求。
    final keys = {for (var i = 0; i < 512; i++) generateUuidV4()};

    expect(keys.length, 512);
  });

  test('可注入随机源以便确定性验证版本位', () {
    // 全 0 字节：仅版本位与变体位被强制置位。
    final uuid = generateUuidV4(_ZeroRandom());

    expect(uuid, '00000000-0000-4000-8000-000000000000');
  });
}

class _ZeroRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}
