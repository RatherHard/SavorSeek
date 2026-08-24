import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'timezone_picker_sheet.dart';

/// 创建行程表单的提交结果。
@immutable
class CreateTripDraft {
  const CreateTripDraft({
    required this.title,
    required this.startDate,
    required this.endDate,
    required this.partySize,
    this.budgetLimitMinor,
    this.timezone = 'Asia/Shanghai',
  });

  final String title;
  final DateTime startDate;
  final DateTime endDate;
  final int partySize;

  /// 预算上限，以分为单位。
  ///
  /// 用整数分而非浮点元：金额用 double 会在累加时产生误差，库中
  /// `budget_limit_minor` 亦为 bigint。
  final int? budgetLimitMinor;

  /// 行程时区（IANA 标识）。
  ///
  /// 在创建时就确定：`validate_trip_row` 规定一旦存在 trip_days 就不得再改时区
  /// （仅受控迁移事务例外），创建后再改要绕 change_trip_timezone 一圈。
  final String timezone;
}

/// 弹出创建行程表单。用户取消时返回 null。
Future<CreateTripDraft?> showCreateTripSheet(BuildContext context) {
  return showModalBottomSheet<CreateTripDraft>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _CreateTripSheet(),
  );
}

class _CreateTripSheet extends StatefulWidget {
  const _CreateTripSheet();

  @override
  State<_CreateTripSheet> createState() => _CreateTripSheetState();
}

class _CreateTripSheetState extends State<_CreateTripSheet> {
  /// 标题上限 80，与 `trips.title` 的 varchar(80) 一致。
  static const int _titleMaxLength = 80;

  /// 人数区间与 `trips_party_size_ck` 一致（1..50）。
  static const int _partySizeMin = 1;
  static const int _partySizeMax = 50;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _budgetController = TextEditingController();

  late DateTime _startDate;
  late DateTime _endDate;
  int _partySize = 2;

  /// 行程时区，默认与库端默认值一致。
  String _timezone = 'Asia/Shanghai';

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _startDate = DateTime(today.year, today.month, today.day);
    _endDate = _startDate;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange() async {
    final today = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      // 允许选今天之前：用户可能在补录已发生的行程。
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 3),
      helpText: '选择行程日期',
      saveText: '确定',
    );
    if (picked == null) return;
    setState(() {
      _startDate = DateUtils.dateOnly(picked.start);
      _endDate = DateUtils.dateOnly(picked.end);
    });
  }

  Future<void> _pickTimezone() async {
    final picked = await showTimezonePickerSheet(context, current: _timezone);
    if (picked == null || !mounted) return;
    setState(() => _timezone = picked);
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final budgetText = _budgetController.text.trim();
    final budgetYuan = budgetText.isEmpty ? null : double.tryParse(budgetText);

    Navigator.of(context).pop(
      CreateTripDraft(
        title: _titleController.text.trim(),
        startDate: _startDate,
        endDate: _endDate,
        partySize: _partySize,
        // 元转分：四舍五入而非截断，避免 99.99 元变成 9998 分。
        budgetLimitMinor: budgetYuan == null
            ? null
            : (budgetYuan * 100).round(),
        timezone: _timezone,
      ),
    );
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
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('规划一段美食行程', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppTokens.spaceLg),
                TextFormField(
                  controller: _titleController,
                  maxLength: _titleMaxLength,
                  textInputAction: TextInputAction.next,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '行程标题',
                    hintText: '例如：大连三日寻味',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    // 库端会 btrim 后校验非空（validate_trip_row），这里提前拦住
                    // 全空格标题，省一次往返。
                    if ((value?.trim() ?? '').isEmpty) return '请填写行程标题';
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _FieldTile(
                  icon: Icons.date_range_outlined,
                  label: '日期',
                  value: formatTripRange(_startDate, _endDate),
                  onTap: _pickDateRange,
                ),
                _FieldTile(
                  icon: Icons.public,
                  label: '时区',
                  value: timezoneLabel(_timezone),
                  onTap: _pickTimezone,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                Row(
                  children: [
                    Icon(
                      Icons.group_outlined,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    Text('人数', style: theme.textTheme.bodyMedium),
                    const Spacer(),
                    IconButton(
                      onPressed: _partySize > _partySizeMin
                          ? () => setState(() => _partySize--)
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: '减少人数',
                    ),
                    Text('$_partySize', style: theme.textTheme.titleMedium),
                    IconButton(
                      onPressed: _partySize < _partySizeMax
                          ? () => setState(() => _partySize++)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: '增加人数',
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextFormField(
                  controller: _budgetController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '预算上限（元，可留空）',
                    hintText: '例如：800',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final trimmed = value?.trim() ?? '';
                    if (trimmed.isEmpty) return null;
                    final parsed = double.tryParse(trimmed);
                    if (parsed == null) return '请填写数字金额';
                    // 库端约束 budget_limit_minor >= 0。
                    if (parsed < 0) return '预算不能为负数';
                    return null;
                  },
                ),
                const SizedBox(height: AppTokens.spaceLg),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceMd),
                    Expanded(
                      child: FilledButton(
                        onPressed: _submit,
                        child: const Text('创建行程'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 把日期区间表述为可读文本。同一天时不重复显示两个相同日期。
String formatTripRange(DateTime start, DateTime end) {
  final startText = '${start.year}-${_two(start.month)}-${_two(start.day)}';
  if (DateUtils.isSameDay(start, end)) return '$startText（当天往返）';
  final days = end.difference(start).inDays + 1;
  return '$startText 起 $days 天';
}

String _two(int value) => value.toString().padLeft(2, '0');

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceMd),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppTokens.spaceSm),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}
