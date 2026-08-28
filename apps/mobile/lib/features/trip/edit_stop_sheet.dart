import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';

import 'schedule_picker_sheet.dart';
import 'trip_duration_picker.dart';
import 'trip_models.dart';
import 'trip_repository.dart';
import 'trip_time_picker.dart';

/// 编辑节点表单的提交结果。
@immutable
class EditStopDraft {
  const EditStopDraft({
    required this.title,
    required this.selection,
    this.notes,
  });

  final String title;
  final ScheduleSelection selection;

  /// null 表示清空备注。
  final String? notes;
}

/// 弹出编辑节点表单，预填当前标题、备注与排期。用户取消时返回 null。
///
/// 编辑一次提交标题、备注、日期、开始时间与时长；服务端用单个 edit_trip_item
/// RPC 保证这些字段不会留下半成品。已完成与已跳过的项不可编辑。
Future<EditStopDraft?> showEditStopSheet(
  BuildContext context, {
  required TripStop stop,
  required TripSchedulingContext trip,
}) {
  return showModalBottomSheet<EditStopDraft>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _EditStopSheet(stop: stop, trip: trip),
  );
}

class _EditStopSheet extends StatefulWidget {
  const _EditStopSheet({required this.stop, required this.trip});

  final TripStop stop;
  final TripSchedulingContext trip;

  @override
  State<_EditStopSheet> createState() => _EditStopSheetState();
}

class _EditStopSheetState extends State<_EditStopSheet> {
  static const int _titleMaxLength = 120;
  static const int _noteMaxLength = 1000;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController = TextEditingController(
    text: widget.stop.title,
  );
  late final TextEditingController _noteController = TextEditingController(
    text: widget.stop.note ?? '',
  );

  late TripDayRef _day = _initialDay();
  late TimeOfDay _time = TimeOfDay(
    hour: widget.stop.startAt.hour,
    minute: widget.stop.startAt.minute,
  );
  late Duration _duration = clampTripStopDuration(
    widget.stop.endAt.difference(widget.stop.startAt),
  );

  TripDayRef _initialDay() {
    for (final day in widget.trip.days) {
      if (day.id == widget.stop.tripDayId) return day;
    }
    return TripDayRef(
      id: widget.stop.tripDayId,
      localDate: DateUtils.dateOnly(widget.stop.startAt),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.localDate,
      firstDate: DateTime(today.year - 10, today.month, today.day),
      lastDate: DateTime(today.year + 10, today.month, today.day),
      helpText: '选择节点日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _day = TripDayRef(localDate: DateUtils.dateOnly(picked)));
  }

  Future<void> _pickTime() async {
    final picked = await showTripTimePicker(
      context,
      initialTime: _time,
      title: '选择开始时间',
    );
    if (picked == null || !mounted) return;
    setState(() => _time = picked);
  }

  Future<void> _pickDuration() async {
    final picked = await showTripDurationPicker(
      context,
      initialDuration: _duration,
    );
    if (picked == null || !mounted) return;
    setState(() => _duration = picked);
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final notes = _noteController.text.trim();
    Navigator.of(context).pop(
      EditStopDraft(
        title: _titleController.text.trim(),
        selection: ScheduleSelection(
          day: _day,
          hour: _time.hour,
          minute: _time.minute,
          duration: _duration,
        ),
        notes: notes.isEmpty ? null : notes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);

    return Padding(
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
                Text('编辑节点', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '一次修改名称、备注与排期。',
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
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if ((value?.trim() ?? '').isEmpty) return '请填写节点名称';
                    return null;
                  },
                ),
                TextFormField(
                  controller: _noteController,
                  maxLength: _noteMaxLength,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '备注（可留空）',
                    hintText: '清空即删除原备注',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _PickerTile(
                  icon: Icons.event_outlined,
                  label: '日期',
                  value: formatLocalDate(_day.localDate),
                  onTap: _pickDate,
                ),
                _PickerTile(
                  icon: Icons.schedule_outlined,
                  label: '开始时间',
                  value: formatWallClock(_time.hour, _time.minute),
                  onTap: _pickTime,
                ),
                _PickerTile(
                  icon: Icons.timer_outlined,
                  label: '停留时长',
                  value: formatTripStopDuration(_duration),
                  onTap: _pickDuration,
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
                        child: const Text('保存'),
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
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
