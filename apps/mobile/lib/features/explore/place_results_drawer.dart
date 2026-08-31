import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/place_card.dart';
import 'package:savorseek/features/places/favorites_controller.dart';
import 'package:savorseek/features/places/place_models.dart';

/// A map-preserving results drawer for the current search batch.
class PlaceResultsDrawer extends StatefulWidget {
  const PlaceResultsDrawer({
    super.key,
    required this.places,
    required this.favorites,
    required this.onSelect,
    this.onToggleFavorite,
    this.onRetryFavorite,
    this.onUnauthenticatedFavorite,
    this.selectedPlaceId,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.paginationError,
    this.onLoadMore,
    this.onRetryPagination,
    this.isPartial = false,
    this.onRetryPartial,
  });

  final List<Place> places;
  final FavoritesController favorites;
  final ValueChanged<Place> onSelect;
  final Future<void> Function(String placeId)? onToggleFavorite;
  final Future<void> Function(String placeId)? onRetryFavorite;
  final Future<void> Function(String placeId)? onUnauthenticatedFavorite;
  final String? selectedPlaceId;
  final bool hasMore;
  final bool isLoadingMore;
  final String? paginationError;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetryPagination;
  final bool isPartial;
  final VoidCallback? onRetryPartial;

  @override
  State<PlaceResultsDrawer> createState() => _PlaceResultsDrawerState();
}

class _PlaceResultsDrawerState extends State<PlaceResultsDrawer> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    if (widget.places.isEmpty && !widget.isPartial) {
      return const SizedBox.shrink();
    }

    return AnimatedSwitcher(
      duration: AppTokens.durationNormal,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _isExpanded ? _buildExpanded(context) : _buildCollapsed(context),
    );
  }

  Widget _buildCollapsed(BuildContext context) {
    final countLabel = '${widget.places.length} 个地点';
    return Align(
      key: const ValueKey('collapsed-place-results'),
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            button: true,
            label: '展开地点列表，共$countLabel',
            child: IconButton(
              onPressed: () => setState(() => _isExpanded = true),
              icon: const Icon(Icons.list_alt_outlined),
              tooltip: '展开地点列表',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context) {
    return DraggableScrollableSheet(
      key: const ValueKey('expanded-place-results'),
      initialChildSize: 0.12,
      minChildSize: 0.12,
      maxChildSize: 0.72,
      snap: true,
      snapSizes: const [0.12, 0.42, 0.72],
      builder: (context, scrollController) => Material(
        elevation: 10,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusMd),
        ),
        clipBehavior: Clip.antiAlias,
        child: CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.spaceMd,
                  AppTokens.spaceSm,
                  AppTokens.spaceMd,
                  AppTokens.spaceXs,
                ),
                child: Column(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        borderRadius: BorderRadius.circular(
                          AppTokens.radiusFull,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.hasMore
                                ? '已加载 ${widget.places.length} 个地点'
                                : '查看 ${widget.places.length} 个地点',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _isExpanded = false),
                          icon: const Icon(Icons.expand_more),
                          tooltip: '收起地点列表',
                        ),
                      ],
                    ),
                    if (widget.isPartial)
                      _DrawerNotice(
                        message: '部分地点已加载，部分区域暂不可用。',
                        actionLabel: widget.onRetryPartial == null
                            ? null
                            : '重试',
                        onAction: widget.onRetryPartial,
                      ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceSm,
                AppTokens.spaceXs,
                AppTokens.spaceSm,
                AppTokens.spaceLg,
              ),
              sliver: SliverList.builder(
                itemCount: widget.places.length,
                itemBuilder: (context, index) {
                  final place = widget.places[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
                    child: PlaceCard(
                      place: place,
                      isFavorite: widget.favorites.isFavorite(place.id),
                      isFavoritePending: _isPending(place.id),
                      selected: place.id == widget.selectedPlaceId,
                      favoriteError: widget.favorites.errorFor(place.id),
                      onRetryFavorite: widget.onRetryFavorite == null
                          ? null
                          : () => widget.onRetryFavorite!(place.id),
                      onUnauthenticatedFavorite:
                          widget.onUnauthenticatedFavorite == null
                          ? null
                          : () => widget.onUnauthenticatedFavorite!(place.id),
                      onSelected: () => widget.onSelect(place),
                      onToggleFavorite: widget.onToggleFavorite == null
                          ? null
                          : () => widget.onToggleFavorite!(place.id),
                    ),
                  );
                },
              ),
            ),
            if (widget.paginationError != null || widget.hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.spaceLg),
                  child: Column(
                    children: [
                      if (widget.paginationError != null)
                        _DrawerNotice(
                          message: widget.paginationError!,
                          actionLabel: widget.onRetryPagination == null
                              ? null
                              : '重试',
                          onAction: widget.onRetryPagination,
                        ),
                      if (widget.hasMore)
                        widget.isLoadingMore
                            ? const Padding(
                                padding: EdgeInsets.all(AppTokens.spaceMd),
                                child: CircularProgressIndicator(),
                              )
                            : OutlinedButton.icon(
                                onPressed: widget.onLoadMore,
                                icon: const Icon(Icons.expand_more),
                                label: const Text('加载更多'),
                              ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _isPending(String placeId) {
    final state = widget.favorites.mutationState(placeId);
    return state == FavoriteMutationState.saving ||
        state == FavoriteMutationState.removing;
  }
}

class _DrawerNotice extends StatelessWidget {
  const _DrawerNotice({required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppTokens.spaceSm),
    child: Row(
      children: [
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ),
  );
}
