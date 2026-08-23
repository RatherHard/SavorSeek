import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase
    show AuthApiException, AuthRetryableFetchException;

/// 认证能力抽象。
///
/// 抽象出接口而非直接用 `Supabase.instance`：Widget 测试无法调用
/// `Supabase.initialize`，注入实现是唯一能让登录流程可测的方式。
abstract interface class AuthService {
  /// 当前会话的用户 id；未登录为 null。
  String? get currentUserId;

  /// 当前会话的登录邮箱；未登录或无邮箱为 null。
  String? get currentEmail;

  bool get isSignedIn;

  /// 会话变化流，登录/登出/令牌刷新时发出当前用户 id（登出为 null）。
  Stream<String?> get userIdChanges;

  Future<void> signIn({required String email, required String password});

  Future<void> signUp({required String email, required String password});

  Future<void> signOut();
}

enum AuthErrorKind {
  invalidCredentials,
  emailTaken,
  weakPassword,
  network,
  unknown,
}

class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.kind = AuthErrorKind.unknown});

  final String message;
  final AuthErrorKind kind;

  @override
  String toString() => message;
}

/// 后端未初始化时的实现：一切操作直接失败并给出原因。
class UnavailableAuthService implements AuthService {
  const UnavailableAuthService([this.reason]);

  final String? reason;

  @override
  String? get currentUserId => null;

  @override
  String? get currentEmail => null;

  @override
  bool get isSignedIn => false;

  @override
  Stream<String?> get userIdChanges => const Stream<String?>.empty();

  @override
  Future<void> signIn({required String email, required String password}) =>
      _fail();

  @override
  Future<void> signUp({required String email, required String password}) =>
      _fail();

  @override
  Future<void> signOut() async {}

  Future<Never> _fail() async {
    throw AuthFailure(reason ?? '账号服务尚未就绪。');
  }
}

/// 基于 Supabase GoTrue 的实现。
///
/// 会话持久化与令牌刷新由 `supabase_flutter` 自行处理，此处不重复实现。
class SupabaseAuthService implements AuthService {
  SupabaseAuthService({GoTrueClient? client})
    : _client = client ?? Supabase.instance.client.auth;

  final GoTrueClient _client;

  @override
  String? get currentUserId => _client.currentUser?.id;

  @override
  String? get currentEmail => _client.currentUser?.email;

  @override
  bool get isSignedIn => _client.currentSession != null;

  @override
  Stream<String?> get userIdChanges =>
      _client.onAuthStateChange.map((state) => state.session?.user.id);

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _guard(
      () => _client.signInWithPassword(email: email, password: password),
    );
  }

  @override
  Future<void> signUp({required String email, required String password}) async {
    // 服务端 GOTRUE_MAILER_AUTOCONFIRM=true，注册即签发会话，无需邮箱验证。
    // 若正式环境收紧该开关，返回的 session 会为 null，需改为提示查收邮件。
    await _guard(() => _client.signUp(email: email, password: password));
  }

  @override
  Future<void> signOut() => _guard(_client.signOut);

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on supabase.AuthApiException catch (error) {
      final kind = authErrorKindFor(code: error.code, statusCode: error.statusCode);
      throw AuthFailure(
        authMessageFor(kind, fallback: error.message),
        kind: kind,
      );
    } on supabase.AuthRetryableFetchException catch (_) {
      throw const AuthFailure(
        '无法连接行程服务，请检查网络后重试。',
        kind: AuthErrorKind.network,
      );
    }
  }
}

/// 将 GoTrue 错误码映射为客户端分支，与 SDK 类型解耦以便单测直接覆盖。
AuthErrorKind authErrorKindFor({String? code, String? statusCode}) {
  return switch (code) {
    'invalid_credentials' || 'invalid_grant' => AuthErrorKind.invalidCredentials,
    'user_already_exists' || 'email_exists' => AuthErrorKind.emailTaken,
    'weak_password' => AuthErrorKind.weakPassword,
    // 旧版 GoTrue 不带 code，仅以 400 表达凭据错误。
    null when statusCode == '400' => AuthErrorKind.invalidCredentials,
    _ => AuthErrorKind.unknown,
  };
}

String authMessageFor(AuthErrorKind kind, {required String fallback}) {
  return switch (kind) {
    AuthErrorKind.invalidCredentials => '邮箱或密码不正确。',
    AuthErrorKind.emailTaken => '该邮箱已注册，请直接登录。',
    AuthErrorKind.weakPassword => '密码强度不足，请至少使用 6 位字符。',
    AuthErrorKind.network => '无法连接行程服务，请检查网络后重试。',
    AuthErrorKind.unknown => fallback,
  };
}
