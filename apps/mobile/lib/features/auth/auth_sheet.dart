import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'auth_service.dart';

/// 弹出邮箱登录/注册面板，登录成功返回 true。
Future<bool> showAuthSheet(
  BuildContext context, {
  required AuthService auth,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      // 键盘弹出时上推，避免输入框被遮挡。
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: AuthSheet(auth: auth),
    ),
  );
  return result ?? false;
}

/// 邮箱登录/注册表单。
///
/// 仅提供邮箱密码方式：服务端 GoTrue 已开放注册且邮箱免验证，这是打通
/// RLS 读取链路的最小实现。
class AuthSheet extends StatefulWidget {
  const AuthSheet({super.key, required this.auth});

  final AuthService auth;

  @override
  State<AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends State<AuthSheet> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    try {
      if (_isSignUp) {
        await widget.auth.signUp(email: email, password: password);
      } else {
        await widget.auth.signIn(email: email, password: password);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isSignUp ? '创建账号' : '登录',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              '行程数据按账号隔离，登录后才能看到属于你的安排。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              enabled: !_isSubmitting,
              decoration: const InputDecoration(
                labelText: '邮箱',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: _validateEmail,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              enabled: !_isSubmitting,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(
                labelText: '密码',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: _validatePassword,
            ),
            if (_errorMessage case final message?) ...[
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isSignUp ? '注册并登录' : '登录'),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            TextButton(
              onPressed: _isSubmitting ? null : _toggleMode,
              child: Text(_isSignUp ? '已有账号，去登录' : '还没有账号，去注册'),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleMode() {
    setState(() {
      _isSignUp = !_isSignUp;
      _errorMessage = null;
    });
  }

  /// 只做形态校验，真正的有效性由服务端判定。
  static String? _validateEmail(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请输入邮箱';
    final atIndex = text.indexOf('@');
    if (atIndex <= 0 || atIndex == text.length - 1) return '邮箱格式不正确';
    return null;
  }

  /// GoTrue 默认最短 6 位，提前拦住可省一次往返。
  static String? _validatePassword(String? value) {
    final text = value ?? '';
    if (text.isEmpty) return '请输入密码';
    if (text.length < 6) return '密码至少 6 位';
    return null;
  }
}
