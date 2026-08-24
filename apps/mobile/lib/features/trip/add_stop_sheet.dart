import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'schedule_picker_sheet.dart';
import 'trip_repository.dart';

/// 添加节点表单的提交结果。
@immutable
class AddStopDraft {
  const AddStopDraft({required this.title, required this.selection, this.note});

  final String title;

  /// 排在哪一天、几点、停留多久。复用加入行程与改期的同一套排期语义。
  final ScheduleSelection selection;

  final String? note;
}

/// 弹出添加节点表单。用户取消时返回 null。
///
/// 节点为 `break` 类型：库端要求地点项必须携带 placeId 与快照，而行程页没有
/// 地点检索能力。地点节点仍从探索页加入，此处提供的是「预留一段时间」这类
/// 不依赖具体地点的安排。
Future<AddStopDraft?> showAddStopSheet(
  BuildContext context, {
  required TripSchedulingContext trip,
}) {
  return showModalBottomSheet<AddStopDraft>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddStopSheet(trip: trip),
  );
}

class _AddStopSheet extends StatefulWidget {
  const _AddStopSheet({required this.trip});

  final TripSchedulingContext trip;

  @override
  State<_AddStopSheet> createState() => _AddStopSheetState();
}

class _AddStopSheetState extends State<_AddStopSheet> {
  /// 标题上限 120，与 `trip_items.title` 的 varchar(120) 一致。
  static const int _titleMaxLength = 120;

  /// 备注上限 1000，与 `trip_items.notes` 的 varchar(1000) 一致。
  static const int _noteMaxLength = 1000;

  /// 可选时长，与排期表单保持一致。
  static const List<int> _durationChoices = [30, 60, 90, 120, 180];

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();

  late TripDayRef _day = widget.trip.days.first;
  TimeOfDay _time = const TimeOfDay(hour: 12, minute: 0);
  Duration _duration = const Duration(hours: 1);

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.localDate,
      // 只允许行程既有的日期：库端要求对应 trip_day 必须已存在。
      firstDate: widget.trip.firstDate,
      lastDate: widget.trip.lastDate,
      selectableDayPredicate: (date) => widget.trip.dayOn(date) != null,
      helpText: '选择行程中的哪一天',
    );
    if (picked == null) return;
    final day = widget.trip.dayOn(picked);
    if (day == null) return;
    setState(() => _day = day);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      helpText: '选择开始时间',
    );
    if (picked == null) return;
    setState(() => _time = picked);
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final note = _noteController.text.trim();
    Navigator.of(context).pop(
      AddStopDraft(
        title: _titleController.text.trim(),
        selection: ScheduleSelection(
          day: _day,
          hour: _time.hour,
          minute: _time.minute,
          duration: _duration,
        ),
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final canPickDate = widget.trip.days.length > 1;

    return Padding(
      // 键盘弹出时上推内容，否则输入框被遮住。
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('添加行程节点', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '用于预留时间、休息或自定义安排。要加入某家店，请在探索页选择地点。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceLg),
                TextFormField(
                  controller: _titleController,
                  maxLength: _titleMaxLength,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '节点名称',
                    hintText: '例如：回酒店休息',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    // 库端 btrim 后校验非空，这里提前拦住全空格标题，省一次往返。
                    if ((value?.trim() ?? '').isEmpty) return '请填写节点名称';
                    return null;
                  },
                ),
                _PickerTile(
                  icon: Icons.event_outlined,
                  label: '日期',
                  value: formatLocalDate(_day.localDate),
                  // 单日行程无从选择，禁用比给一个只有一个选项的弹窗更诚实。
                  onTap: canPickDate ? _pickDate : null,
                ),
                const Divider(height: 1),
                _PickerTile(
                  icon: Icons.schedule_outlined,
                  label: '开始时间',
                  value: formatWallClock(_time.hour, _time.minute),
                  onTap: _pickTime,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                Text('持续时长', style: theme.textTheme.labelLarge),
                const SizedBox(height: AppTokens.spaceSm),
                Wrap(
                  spacing: AppTokens.spaceSm,
                  children: _durationChoices.map((minutes) {
                    return ChoiceChip(
                      label: Text(formatDuration(Duration(minutes: minutes))),
                      selected: _duration.inMinutes == minutes,
                      onSelected: (_) => setState(
                        () => _duration = Duration(minutes: minutes),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextFormField(
                  controller: _noteController,
                  maxLength: _noteMaxLength,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '备注（可留空）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
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
                        child: const Text('添加'),
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

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;

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
                color: enabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (enabled) const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}
