import 'package:flutter/material.dart';

import 'package:savorseek/app/theme/design_tokens.dart';
import 'package:savorseek/features/explore/amap_consent.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';

import 'pick_place_sheet.dart';
import 'schedule_picker_sheet.dart';
import 'trip_repository.dart';

/// 统一添加入口返回的草稿。
@immutable
class AddStopDraft {
  const AddStopDraft({
    required this.title,
    required this.selection,
    this.place,
    this.note,
  });

  final String title;
  final ScheduleSelection selection;
  final Place? place;
  final String? note;
}

/// 添加一个节点；地点关联是可选的。
Future<AddStopDraft?> showAddStopSheet(
  BuildContext context, {
  required TripSchedulingContext trip,
  PlaceRepository? placeRepository,
  AmapConsent? mapConsent,
}) {
  return showModalBottomSheet<AddStopDraft>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddStopSheet(
      trip: trip,
      placeRepository: placeRepository,
      mapConsent: mapConsent,
    ),
  );
}

class _AddStopSheet extends StatefulWidget {
  const _AddStopSheet({
    required this.trip,
    this.placeRepository,
    this.mapConsent,
  });

  final TripSchedulingContext trip;
  final PlaceRepository? placeRepository;
  final AmapConsent? mapConsent;

  @override
  State<_AddStopSheet> createState() => _AddStopSheetState();
}

class _AddStopSheetState extends State<_AddStopSheet> {
  static const int _titleMaxLength = 120;
  static const int _noteMaxLength = 1000;
  static const List<int> _durationChoices = [30, 60, 90, 120, 180];

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();

  late TripDayRef _day = widget.trip.days.first;
  TimeOfDay _time = const TimeOfDay(hour: 12, minute: 0);
  Duration _duration = const Duration(hours: 1);
  Place? _place;

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickPlace() async {
    final repository = widget.placeRepository;
    if (repository == null) return;
    final place = await showPickPlaceSheet(
      context,
      placeRepository: repository,
      consent: widget.mapConsent,
    );
    if (place == null || !mounted) return;
    setState(() {
      _place = place;
      if (_titleController.text.trim().isEmpty) {
        _titleController.text = place.name;
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.localDate,
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
        place: _place,
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
                  '可关联一个地点；不关联时就是自由安排节点。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                if (widget.placeRepository != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _place == null
                          ? Icons.add_location_alt_outlined
                          : Icons.place_outlined,
                    ),
                    title: Text(_place?.name ?? '关联地点（可选）'),
                    subtitle: Text(_place == null ? '搜索并选择地点' : '点击更换地点'),
                    trailing: _place == null
                        ? const Icon(Icons.chevron_right)
                        : IconButton(
                            tooltip: '清除地点',
                            onPressed: () => setState(() => _place = null),
                            icon: const Icon(Icons.clear),
                          ),
                    onTap: _pickPlace,
                  ),
                TextFormField(
                  controller: _titleController,
                  maxLength: _titleMaxLength,
                  autofocus: widget.placeRepository == null,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '节点名称',
                    hintText: '例如：回酒店休息',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if ((value?.trim() ?? '').isEmpty) return '请填写节点名称';
                    return null;
                  },
                ),
                _PickerTile(
                  icon: Icons.event_outlined,
                  label: '日期',
                  value: formatLocalDate(_day.localDate),
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
                  children: [
                    for (final minutes in _durationChoices)
                      ChoiceChip(
                        label: Text(formatDuration(Duration(minutes: minutes))),
                        selected: _duration.inMinutes == minutes,
                        onSelected: (_) => setState(
                          () => _duration = Duration(minutes: minutes),
                        ),
                      ),
                  ],
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
