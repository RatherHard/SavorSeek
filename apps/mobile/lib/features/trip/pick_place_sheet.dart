import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/places/place_search_controller.dart';

/// 在行程页内检索并选择一个地点。用户取消时返回 null。
///
/// 为什么行程页也要有检索：地点节点是路线能成立的前提（只有它带坐标），而此前唯一
/// 的入口在探索页。用户在行程里发现「这天还缺一家店」时，得先离开行程、切到探索页、
/// 搜索、加入、再切回来，中途还要自己记住是哪一天缺。
///
/// 复用 [PlaceSearchController] 而非另写一套：过期响应丢弃、空结果与失败分离这些
/// 规则已在探索页验证过，重写一遍必然漂移成两种行为。
Future<Place?> showPickPlaceSheet(
  BuildContext context, {
  required PlaceRepository placeRepository,
  String? city,
}) {
  return showModalBottomSheet<Place>(
    context: context,
    isScrollControlled: true,
    builder: (context) =>
        _PickPlaceSheet(placeRepository: placeRepository, city: city),
  );
}

class _PickPlaceSheet extends StatefulWidget {
  const _PickPlaceSheet({required this.placeRepository, this.city});

  final PlaceRepository placeRepository;

  /// 限定检索城市。为空时不限定，「烧烤」这类通用词可能返回外地结果。
  final String? city;

  @override
  State<_PickPlaceSheet> createState() => _PickPlaceSheetState();
}

class _PickPlaceSheetState extends State<_PickPlaceSheet> {
  late final PlaceSearchController _controller = PlaceSearchController(
    widget.placeRepository,
  );
  final _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _queryController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _search() async {
    final keywords = _queryController.text.trim();
    if (keywords.isEmpty) return;
    await _controller.searchByKeywords(keywords, city: widget.city);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);

    return Padding(
      // 键盘弹出时上推内容，否则输入框被遮住。
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('添加地点', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                '搜索一家店加入这次行程。带位置的地点才能显示在地图上。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              TextField(
                controller: _queryController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: '搜索地点',
                  hintText: '例如：海鲜面馆',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: '搜索',
                    // 检索中禁用：两次并发检索的结果会互相覆盖。
                    onPressed: _controller.isLoading ? null : _search,
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              // 固定高度而非 Expanded：本表单是 min 高度的底部弹层，
              // Expanded 在无界高度中会抛异常。
              SizedBox(height: 280, child: _buildResults()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    return switch (_controller.state) {
      PlaceSearchIdle() => const _Hint(
        icon: Icons.travel_explore_outlined,
        text: '输入店名或菜系开始搜索。',
      ),
      PlaceSearchLoading() => const Center(child: CircularProgressIndicator()),
      PlaceSearchEmpty(:final keywords) => _Hint(
        icon: Icons.search_off_outlined,
        text: '没有找到与「$keywords」相符的地点。\n换个说法或换个菜系再试。',
      ),
      // 可重试与不可重试分开：Key 缺失或被拒属服务端配置问题，
      // 给出重试按钮只会让用户反复徒劳。
      PlaceSearchFailed(:final message, :final isRetryable) => _Hint(
        icon: Icons.cloud_off_outlined,
        text: message,
        onRetry: isRetryable
            ? () => _controller.retry(city: widget.city)
            : null,
      ),
      PlaceSearchLoaded(:final places) => ListView.separated(
        itemCount: places.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) => _PlaceTile(
          place: places[index],
          onTap: () => Navigator.of(context).pop(places[index]),
        ),
      ),
    };
  }
}

/// 结果列表里的一个地点。
class _PlaceTile extends StatelessWidget {
  const _PlaceTile({required this.place, required this.onTap});

  final Place place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final located = place.hasCoordinates;
    // 三段说明按有值者拼接：类别与地址都可能缺失，缺一段时不该留下孤立的分隔符。
    final details = [
      ?place.primaryCategory,
      ?place.address,
      if (!located) '无位置信息，不会显示在地图上',
    ].where((part) => part.isNotEmpty);

    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        // 无坐标的地点仍可加入，但上不了地图，图标先把这件事说清楚。
        located ? Icons.place_outlined : Icons.location_off_outlined,
        color: located ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        details.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.add_circle_outline, size: 20),
    );
  }
}

/// 初始态、空结果与失败态的统一呈现。
class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.onRetry});

  final IconData icon;
  final String text;

  /// 为空时不给重试按钮。
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (onRetry case final retry?) ...[
              const SizedBox(height: AppTokens.spaceMd),
              OutlinedButton.icon(
                onPressed: retry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
