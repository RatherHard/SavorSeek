import 'dart:math';

/// 生成 RFC 4122 v4 UUID。
///
/// 自行实现而非依赖 `uuid` 包：唯一用途是 RPC 幂等键，仅需 16 字节随机值加
/// 版本位，为此引入一个直接依赖不划算。使用 [Random.secure] 以避免同一毫秒内
/// 多次写入产生可预测的重复键。
String generateUuidV4([Random? random]) {
  final rng = random ?? _secureRandom;
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final Random _secureRandom = Random.secure();
