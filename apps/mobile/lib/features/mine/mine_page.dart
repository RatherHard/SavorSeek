import 'dart:async';

import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/auth/auth_sheet.dart';
import 'package:savorseek/features/places/favorites_controller.dart';
import 'package:savorseek/features/places/place_detail_sheet.dart';
import 'package:savorseek/features/places/place_models.dart';

/// 我的页（P-MINE）。
class MinePage extends StatefulWidget {
  const MinePage({
    super.key,
    this.auth,
    this.favoriteController,
    this.isActive = true,
  });

  final AuthService? auth;
  final FavoritesController? favoriteController;
  final bool isActive;

  static const List<({IconData icon, String label})> sections = [
    (icon: Icons.insights_outlined, label: '偏好分析'),
    (icon: Icons.bookmark_outline, label: '收藏的地点'),
    (icon: Icons.account_circle_outlined, label: '账号管理'),
  ];

  static const String accountLabel = '账号管理';

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  StreamSubscription<String?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    widget.favoriteController?.addListener(_onFavoritesChanged);
    _authSubscription = widget.auth?.userIdChanges.listen((_) {
      if (!mounted) return;
      setState(() {});
      if (widget.auth?.isSignedIn == true) {
        unawaited(widget.favoriteController?.loadFavorites());
      }
    });
    if (widget.auth?.isSignedIn == true) {
      unawaited(widget.favoriteController?.loadFavorites());
    }
  }

  @override
  void didUpdateWidget(covariant MinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive &&
        widget.isActive &&
        widget.auth?.isSignedIn == true) {
      unawaited(widget.favoriteController?.loadFavorites());
    }
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    widget.favoriteController?.removeListener(_onFavoritesChanged);
    super.dispose();
  }

  Future<void> _handleAccountTap() async {
    final auth = widget.auth;
    if (auth == null) return;
    if (auth.isSignedIn) {
      await auth.signOut();
    } else {
      await showAuthSheet(context, auth: auth);
    }
    if (mounted) setState(() {});
  }

  Future<void> _openFavorite(Place place) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AnimatedBuilder(
        animation: widget.favoriteController!,
        builder: (context, _) => PlaceDetailSheet(
          place: place,
          onClose: () => Navigator.of(context).pop(),
          isFavorite: widget.favoriteController!.isFavorite(place.id),
          isFavoritePending: _isPending(place.id),
          onFavorite: () => widget.favoriteController!.toggle(place.id),
          onRetryFavorite: () => widget.favoriteController!.retry(place.id),
          favoriteError: widget.favoriteController!.errorFor(place.id),
        ),
      ),
    );
  }

  bool _isPending(String placeId) {
    final state = widget.favoriteController!.mutationState(placeId);
    return state == FavoriteMutationState.saving ||
        state == FavoriteMutationState.removing;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = widget.auth;
    final favorites = widget.favoriteController;

    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: [
        _SectionCard(
          icon: Icons.insights_outlined,
          title: '偏好分析',
          subtitle: '收藏和行程积累后，这里会展示你的口味线索。',
          enabled: false,
        ),
        const SizedBox(height: AppTokens.spaceSm),
        _FavoritesCard(
          controller: favorites,
          isSignedIn: auth?.isSignedIn == true,
          onLogin: auth == null
              ? null
              : () => showAuthSheet(context, auth: auth),
          onRetry: favorites == null ? null : () => favorites.loadFavorites(),
          onOpen: _openFavorite,
        ),
        const SizedBox(height: AppTokens.spaceSm),
        _SectionCard(
          icon: Icons.account_circle_outlined,
          title: MinePage.accountLabel,
          subtitle: _accountSubtitle(auth),
          enabled: auth != null,
          trailing: auth == null
              ? null
              : Icon(
                  auth.isSignedIn ? Icons.logout : Icons.login,
                  color: scheme.primary,
                ),
          onTap: _handleAccountTap,
        ),
        const SizedBox(height: AppTokens.spaceSm),
      ],
    );
  }

  String _accountSubtitle(AuthService? auth) {
    if (auth == null) return '账号服务尚未就绪';
    if (!auth.isSignedIn) return '未登录 · 点击登录或注册';
    return auth.currentEmail ?? '已登录';
  }
}

class _FavoritesCard extends StatelessWidget {
  const _FavoritesCard({
    required this.controller,
    required this.isSignedIn,
    required this.onLogin,
    required this.onRetry,
    required this.onOpen,
  });

  final FavoritesController? controller;
  final bool isSignedIn;
  final VoidCallback? onLogin;
  final VoidCallback? onRetry;
  final ValueChanged<Place> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = controller;
    Widget content;
    if (current == null || !isSignedIn) {
      content = _StateText(
        text: '登录后即可保存想去的地点。',
        actionLabel: onLogin == null ? null : '登录',
        onAction: onLogin,
      );
    } else {
      content = switch (current.listStatus) {
        FavoriteListStatus.idle || FavoriteListStatus.loading =>
          const _StateText(text: '正在加载收藏…', showProgress: true),
        FavoriteListStatus.empty => const _StateText(text: '还没有收藏地点。'),
        FavoriteListStatus.failed => _StateText(
          text: current.listError?.message ?? '收藏服务暂时不可用。',
          actionLabel: current.listError?.isRetryable == true ? '重试' : null,
          onAction: onRetry,
        ),
        FavoriteListStatus.loaded => ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: current.favoritePlaces.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final favorite = current.favoritePlaces[index];
            final place = favorite.place;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                place.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  ?place.primaryCategory,
                  ?place.address,
                  if (!place.hasCoordinates) '无坐标',
                  '更新于${formatFreshness(place.fetchedAt)}',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              leading: Icon(
                place.hasCoordinates ? Icons.bookmark : Icons.bookmark_border,
                color: scheme.primary,
              ),
              trailing: IconButton(
                tooltip: '取消收藏 ${place.name}',
                onPressed: _isPending(current, place.id)
                    ? null
                    : () => current.toggle(place.id),
                icon: _isPending(current, place.id)
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.remove_circle_outline),
              ),
              onTap: () => onOpen(place),
            );
          },
        ),
      };
    }

    return _SectionCard(
      icon: Icons.bookmark_outline,
      title: '收藏的地点',
      subtitle: null,
      enabled: false,
      child: content,
    );
  }

  static bool _isPending(FavoritesController controller, String placeId) {
    final state = controller.mutationState(placeId);
    return state == FavoriteMutationState.saving ||
        state == FavoriteMutationState.removing;
  }
}

class _StateText extends StatelessWidget {
  const _StateText({
    required this.text,
    this.showProgress = false,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final bool showProgress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (showProgress)
        const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      Expanded(child: Text(text)),
      if (actionLabel != null)
        TextButton(onPressed: onAction, child: Text(actionLabel!)),
    ];
    return Row(children: children);
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    this.trailing,
    this.onTap,
    this.child,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: scheme.onSurfaceVariant),
                  const SizedBox(width: AppTokens.spaceSm),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ?trailing,
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (child != null) ...[
                const SizedBox(height: AppTokens.spaceSm),
                child!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
