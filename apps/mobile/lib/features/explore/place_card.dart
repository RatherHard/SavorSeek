import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/places/favorite_repository.dart';
import 'package:savorseek/features/places/place_detail_sheet.dart';
import 'package:savorseek/features/places/place_models.dart';

/// A compact, accessible projection of one place in the results list.
class PlaceCard extends StatelessWidget {
  const PlaceCard({
    super.key,
    required this.place,
    required this.isFavorite,
    required this.isFavoritePending,
    required this.onSelected,
    required this.onToggleFavorite,
    this.favoriteError,
    this.onRetryFavorite,
    this.onUnauthenticatedFavorite,
    this.selected = false,
  });

  final Place place;
  final bool isFavorite;
  final bool isFavoritePending;
  final bool selected;
  final VoidCallback onSelected;
  final Future<void> Function()? onToggleFavorite;
  final FavoriteRepositoryException? favoriteError;
  final Future<void> Function()? onRetryFavorite;
  final Future<void> Function()? onUnauthenticatedFavorite;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final category = place.primaryCategory;
    final favoriteLabel = isFavoritePending
        ? '正在保存 ${place.name}'
        : isFavorite
        ? '取消收藏 ${place.name}'
        : '收藏 ${place.name}';

    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surface,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelected,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceSm,
            AppTokens.spaceXs,
            AppTokens.spaceSm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (category != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                        child: Text(
                          category,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    if (place.address != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                        child: Text(
                          place.address!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                      child: Text(
                        place.hasCoordinates
                            ? '信息更新于${formatFreshness(place.fetchedAt)}'
                            : '无坐标 · 信息更新于${formatFreshness(place.fetchedAt)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (favoriteError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                favoriteError!.message,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.error,
                                ),
                              ),
                            ),
                            if (onRetryFavorite != null &&
                                favoriteError!.isRetryable)
                              TextButton(
                                onPressed: onRetryFavorite,
                                child: const Text('重试'),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Semantics(
                button: true,
                label: favoriteLabel,
                child: IconButton(
                  onPressed: isFavoritePending
                      ? null
                      : onToggleFavorite ?? onUnauthenticatedFavorite,
                  icon: isFavoritePending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          isFavorite ? Icons.bookmark : Icons.bookmark_border,
                        ),
                  tooltip: favoriteLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
