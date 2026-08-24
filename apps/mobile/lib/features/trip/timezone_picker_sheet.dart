import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'trip_time_zone.dart';

/// 常用目的地时区。
///
/// 不列出全部 IANA 时区（数据集有 341 个）：绝大多数与美食旅行无关，长列表反而让
/// 用户难以找到目标。这里按国内出行的常见目的地排列，其余情形由搜索兜住。
const List<({String id, String label})> commonTimezones = [
  (id: 'Asia/Shanghai', label: '中国大陆（北京时间）'),
  (id: 'Asia/Hong_Kong', label: '中国香港'),
  (id: 'Asia/Macau', label: '中国澳门'),
  (id: 'Asia/Taipei', label: '中国台北'),
  (id: 'Asia/Tokyo', label: '日本（东京）'),
  (id: 'Asia/Seoul', label: '韩国（首尔）'),
  (id: 'Asia/Singapore', label: '新加坡'),
  (id: 'Asia/Bangkok', label: '泰国（曼谷）'),
  (id: 'Asia/Kuala_Lumpur', label: '马来西亚（吉隆坡）'),
  (id: 'Asia/Jakarta', label: '印尼（雅加达）'),
  (id: 'Asia/Dubai', label: '阿联酋（迪拜）'),
  (id: 'Europe/London', label: '英国（伦敦）'),
  (id: 'Europe/Paris', label: '法国（巴黎）'),
  (id: 'Europe/Rome', label: '意大利（罗马）'),
  (id: 'Europe/Madrid', label: '西班牙（马德里）'),
  (id: 'America/New_York', label: '美国东部（纽约）'),
  (id: 'America/Los_Angeles', label: '美国西部（洛杉矶）'),
  (id: 'Australia/Sydney', label: '澳大利亚（悉尼）'),
];

/// 时区的中文名。未收录于 [commonTimezones] 时退回 IANA 标识本身。
///
/// 与选择器共用同一张表：另建一份映射必然与列表漂移，出现「选了东京、显示
/// Asia/Tokyo」这类不一致。
String timezoneLabel(String id) {
  for (final zone in commonTimezones) {
    if (zone.id == id) return zone.label;
  }
  return id;
}

/// 弹出时区选择表单，返回所选 IANA 标识。用户取消时返回 null。
Future<String?> showTimezonePickerSheet(
  BuildContext context, {
  required String current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TimezonePickerSheet(current: current),
  );
}

class _TimezonePickerSheet extends StatefulWidget {
  const _TimezonePickerSheet({required this.current});

  final String current;

  @override
  State<_TimezonePickerSheet> createState() => _TimezonePickerSheetState();
}

class _TimezonePickerSheetState extends State<_TimezonePickerSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 匹配常用列表；输入形如 `Asia/Xxx` 且时区库认得时，作为额外候选给出。
  List<({String id, String label})> get _visible {
    if (_query.isEmpty) return commonTimezones;
    final lower = _query.toLowerCase();
    final matched = commonTimezones
        .where(
          (item) =>
              item.label.contains(_query) ||
              item.id.toLowerCase().contains(lower),
        )
        .toList();
    // 允许直接输入 IANA 标识以覆盖列表之外的目的地。先校验时区库认得，
    // 否则提交后才被库端以 22023 拒绝。
    final isKnownId =
        !commonTimezones.any((item) => item.id == _query) &&
        TripTimeZone.isSupported(_query);
    if (isKnownId) {
      matched.add((id: _query, label: '自定义时区'));
    }
    return matched;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = _visible;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceLg,
                AppTokens.spaceLg,
                AppTokens.spaceLg,
                AppTokens.spaceSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选择行程时区', style: theme.textTheme.titleLarge),
                  const SizedBox(height: AppTokens.spaceXs),
                  Text(
                    '各行程项保留当地钟点：原本 19:00 的安排，改时区后仍是当地 19:00。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppTokens.spaceMd),
                  TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: '搜索城市，或直接输入如 Asia/Osaka',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(AppTokens.spaceLg),
                      child: Text(
                        '没有匹配的时区。可输入完整的 IANA 标识，例如 Asia/Osaka。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final selected = item.id == widget.current;
                        return ListTile(
                          title: Text(item.label),
                          subtitle: Text(item.id),
                          trailing: selected
                              ? Icon(Icons.check, color: scheme.primary)
                              : null,
                          // 当前时区不可再选：点了没有任何变化。
                          onTap: selected
                              ? null
                              : () => Navigator.of(context).pop(item.id),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
