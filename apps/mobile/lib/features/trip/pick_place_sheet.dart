import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/explore/amap_surface.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/places/place_search_controller.dart';

/// 在行程页内检索并选择一个地点。用户取消时返回 null。
///
/// 地图只用于帮助确认地点，不直接提交：点标记或列表行先进入选中态，用户还要
/// 点击「确认地点」才会离开表单，避免误触地图就写入行程。
Future<Place?> showPickPlaceSheet(
  BuildContext context, {
  required PlaceRepository placeRepository,
  required AmapConsent? consent,
  String? city,
}) {
  return showModalBottomSheet<Place>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _PickPlaceSheet(
      placeRepository: placeRepository,
      consent: consent,
      city: city,
    ),
  );
}

class _PickPlaceSheet extends StatefulWidget {
  const _PickPlaceSheet({
    required this.placeRepository,
    required this.consent,
    this.city,
  });

  final PlaceRepository placeRepository;
  final AmapConsent? consent;
  final String? city;

  @override
  State<_PickPlaceSheet> createState() => _PickPlaceSheetState();
}

class _PickPlaceSheetState extends State<_PickPlaceSheet> {
  late final PlaceSearchController _controller = PlaceSearchController(
    widget.placeRepository,
  );
  final _queryController = TextEditingController();
  AMapController? _mapController;
  Place? _selectedPlace;

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
    setState(() => _selectedPlace = null);
    await _controller.searchByKeywords(keywords, city: widget.city);
  }

  bool _canShowMap(List<Place> places) {
    return widget.consent?.agreed == true &&
        places.any((place) => place.hasCoordinates);
  }

  Set<Marker> _markersFor(List<Place> places) {
    return {
      for (final place in places)
        if (place.hasCoordinates)
          Marker(
            position: LatLng(place.latitude!, place.longitude!),
            infoWindow: InfoWindow(title: place.name),
            onTap: (_) => _selectPlace(place),
          ),
    };
  }

  void _selectPlace(Place place) {
    setState(() => _selectedPlace = place);
    final controller = _mapController;
    if (controller == null || !place.hasCoordinates) return;
    controller.moveCamera(
      CameraUpdate.newLatLngZoom(LatLng(place.latitude!, place.longitude!), 16),
    );
  }

  void _confirmSelection() {
    final place = _selectedPlace;
    if (place == null) return;
    Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);

    return Padding(
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
                '搜索后先确认地点，再加入行程。带位置的地点才能显示在地图上。',
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
                    onPressed: _controller.isLoading ? null : _search,
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              SizedBox(height: 360, child: _buildResults()),
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
      PlaceSearchFailed(:final message, :final isRetryable) => _Hint(
        icon: Icons.cloud_off_outlined,
        text: message,
        onRetry: isRetryable
            ? () => _controller.retry(city: widget.city)
            : null,
      ),
      PlaceSearchLoaded(:final places) => _LoadedResults(
        places: places,
        selectedPlace: _selectedPlace,
        showMap: _canShowMap(places),
        markers: _markersFor(places),
        onMapCreated: (controller) => _mapController = controller,
        onSelect: _selectPlace,
        onConfirm: _confirmSelection,
      ),
    };
  }
}

class _LoadedResults extends StatelessWidget {
  const _LoadedResults({
    required this.places,
    required this.selectedPlace,
    required this.showMap,
    required this.markers,
    required this.onMapCreated,
    required this.onSelect,
    required this.onConfirm,
  });

  final List<Place> places;
  final Place? selectedPlace;
  final bool showMap;
  final Set<Marker> markers;
  final ValueChanged<AMapController> onMapCreated;
  final ValueChanged<Place> onSelect;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showMap)
          SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              child: AmapSurface(
                markers: markers,
                onMapCreated: onMapCreated,
                gesturesEnabled: false,
                eagerGestures: false,
              ),
            ),
          ),
        if (showMap) const SizedBox(height: AppTokens.spaceSm),
        Expanded(
          child: ListView.separated(
            itemCount: places.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) => _PlaceTile(
              place: places[index],
              selected: places[index].id == selectedPlace?.id,
              onTap: () => onSelect(places[index]),
            ),
          ),
        ),
        if (selectedPlace case final place?) ...[
          const SizedBox(height: AppTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: Text(
                  '已选：${place.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FilledButton(onPressed: onConfirm, child: const Text('确认地点')),
            ],
          ),
        ],
      ],
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.place,
    required this.selected,
    required this.onTap,
  });

  final Place place;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final located = place.hasCoordinates;
    final details = [
      ?place.primaryCategory,
      ?place.address,
      if (!located) '无位置信息，不会显示在地图上',
    ].where((part) => part.isNotEmpty);

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        located ? Icons.place_outlined : Icons.location_off_outlined,
        color: located ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        details.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.onRetry});

  final IconData icon;
  final String text;
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
