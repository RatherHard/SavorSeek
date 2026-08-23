import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/trip/trip_repository.dart';

void main() {
  group('PostgREST 错误码映射', () {
    test('未认证映射到 unauthenticated', () {
      // 28000 来自 RPC 的 raise exception；PGRST301 是 JWT 过期。
      for (final code in ['28000', 'PGRST301']) {
        final error = translatePostgrestError(code: code, message: 'x');
        expect(error.kind, TripRepositoryErrorKind.unauthenticated);
      }
    });

    test('revision 冲突映射到 conflict 并提示重新加载', () {
      // P0002 是 RPC 显式抛出的冲突码；40001 是真正的串行化失败，处置相同。
      for (final code in ['P0002', '40001']) {
        final error = translatePostgrestError(code: code, message: 'x');

        expect(error.kind, TripRepositoryErrorKind.conflict);
        expect(error.message, contains('重新加载'));
      }
    });

    test('权限不足映射到 unauthenticated', () {
      // 表权限已 revoke，直接 insert 会得到 42501；RPC 内 trip not found 同码。
      final error = translatePostgrestError(code: '42501', message: 'x');

      expect(error.kind, TripRepositoryErrorKind.unauthenticated);
    });

    test('未知错误保留原始信息并归为 unavailable', () {
      final error = translatePostgrestError(
        code: '22023',
        message: 'trip dates are required',
      );

      expect(error.kind, TripRepositoryErrorKind.unavailable);
      expect(error.message, 'trip dates are required');
    });
  });

  group('GoTrue 错误码映射', () {
    test('凭据错误可被识别', () {
      expect(
        authErrorKindFor(code: 'invalid_credentials'),
        AuthErrorKind.invalidCredentials,
      );
      // 旧版 GoTrue 不带 code，仅以 400 表达。
      expect(
        authErrorKindFor(code: null, statusCode: '400'),
        AuthErrorKind.invalidCredentials,
      );
    });

    test('邮箱占用与弱密码分别可被识别', () {
      expect(authErrorKindFor(code: 'email_exists'), AuthErrorKind.emailTaken);
      expect(
        authErrorKindFor(code: 'weak_password'),
        AuthErrorKind.weakPassword,
      );
    });

    test('未知错误回落到服务端原文', () {
      const raw = 'signups not allowed for this instance';
      final kind = authErrorKindFor(code: 'signup_disabled');

      expect(kind, AuthErrorKind.unknown);
      expect(authMessageFor(kind, fallback: raw), raw);
    });
  });
}
