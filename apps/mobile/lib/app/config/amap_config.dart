import 'dart:io' show Platform;

/// 高德 SDK Key 配置。
///
/// **Android**：Key 由 `app/build.gradle.kts` 在构建期从 `amap.env` 读入，
/// 注入到 `AndroidManifest` 的 `com.amap.api.v2.apikey` meta-data。原生 SDK
/// 直接读取该值，因此 IDE 运行、`flutter run`、`flutter build` 都生效，
/// 不依赖任何命令行参数。
///
/// **iOS**：无等价的 manifest 机制，Key 只能经 Dart 侧传入，因此仍通过
/// `--dart-define-from-file=amap.env` 注入。
///
/// Key 不具备运行期机密性（注入值会进入产物二进制），其安全性由高德控制台
/// 侧的「PackageName / BundleID + 签名指纹」绑定保证，不入库仅为避免密钥
/// 随源码扩散。
abstract final class AmapConfig {
  /// Android Key 的可选覆盖值。
  ///
  /// 正常构建下为空——Android 的 Key 来自 manifest。仅在需要临时覆盖时
  /// 通过 `--dart-define` 传入。
  static const String _androidKeyOverride =
      String.fromEnvironment('AMAP_ANDROID_KEY');

  static const String _iosKey = String.fromEnvironment('AMAP_IOS_KEY');

  /// 需要经 Dart 侧下发给 SDK 的 Key；为空表示交由原生侧自行读取。
  ///
  /// 关键：绝不能把空字符串传给插件。插件的 `checkApiKey` 只判空引用、
  /// 不判空串，传入 `''` 会调用 `MapsInitializer.setApiKey('')`，
  /// 把 manifest 中已注入的有效 Key 覆盖掉，导致地图鉴权失败。
  static String? get androidKey =>
      _androidKeyOverride.isEmpty ? null : _androidKeyOverride;

  static String? get iosKey => _iosKey.isEmpty ? null : _iosKey;

  /// 当前平台是否仍缺少可用的 Key 配置。
  ///
  /// Android 恒为 false：Key 在构建期注入 manifest，缺失会由 Gradle 侧发出
  /// 警告（发布构建直接失败），运行期无法也无需再判断。
  /// iOS 依赖 Dart 注入，可在运行期判断。
  static bool get isKeyMissing {
    if (Platform.isIOS) return iosKey == null;
    return false;
  }
}
