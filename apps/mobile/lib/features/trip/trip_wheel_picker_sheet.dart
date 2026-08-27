import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

const double tripWheelPickerHeight = 176;
const double _tripWheelPickerFadeExtent = 36;

/// A compact numeric wheel whose edge treatment is limited to the number column.
class TripWheelNumberColumn extends StatefulWidget {
  const TripWheelNumberColumn({
    super.key,
    required this.values,
    required this.initialIndex,
    required this.labelBuilder,
    required this.onSelectedItemChanged,
    this.width = 56,
  });

  final List<int> values;
  final int initialIndex;
  final String Function(int value) labelBuilder;
  final ValueChanged<int> onSelectedItemChanged;
  final double width;

  @override
  State<TripWheelNumberColumn> createState() => _TripWheelNumberColumnState();
}

class _TripWheelNumberColumnState extends State<TripWheelNumberColumn> {
  late final FixedExtentScrollController _controller =
      FixedExtentScrollController(initialItem: widget.initialIndex);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final edgeFade = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        surface.withValues(alpha: 0),
        surface,
        surface,
        surface.withValues(alpha: 0),
      ],
      stops: [
        0,
        _tripWheelPickerFadeExtent / tripWheelPickerHeight,
        1 - _tripWheelPickerFadeExtent / tripWheelPickerHeight,
        1,
      ],
    );
    return SizedBox(
      width: widget.width,
      height: tripWheelPickerHeight,
      child: ShaderMask(
        shaderCallback: (bounds) => edgeFade.createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: CupertinoPicker.builder(
          scrollController: _controller,
          itemExtent: 40,
          childCount: widget.values.length,
          useMagnifier: true,
          magnification: 1.08,
          onSelectedItemChanged: (index) {
            widget.onSelectedItemChanged(widget.values[index]);
          },
          itemBuilder: (context, index) => Center(
            child: Text(
              widget.labelBuilder(widget.values[index]),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showTripWheelPickerSheet<T>(
  BuildContext context, {
  required String title,
  required T initialValue,
  required Widget Function(BuildContext context, ValueChanged<T> onChanged)
  pickerBuilder,
  String? helperText,
  bool Function(T value)? isValueValid,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TripWheelPickerSheet<T>(
      title: title,
      initialValue: initialValue,
      pickerBuilder: pickerBuilder,
      helperText: helperText,
      isValueValid: isValueValid,
    ),
  );
}

class _TripWheelPickerSheet<T> extends StatefulWidget {
  const _TripWheelPickerSheet({
    required this.title,
    required this.initialValue,
    required this.pickerBuilder,
    this.helperText,
    this.isValueValid,
  });

  final String title;
  final T initialValue;
  final Widget Function(BuildContext context, ValueChanged<T> onChanged)
  pickerBuilder;
  final String? helperText;
  final bool Function(T value)? isValueValid;

  @override
  State<_TripWheelPickerSheet<T>> createState() =>
      _TripWheelPickerSheetState<T>();
}

class _TripWheelPickerSheetState<T> extends State<_TripWheelPickerSheet<T>> {
  late T _value = widget.initialValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isValid = widget.isValueValid?.call(_value) ?? true;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.65;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(widget.title, style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 8),
              _TripWheelPickerViewport(
                child: widget.pickerBuilder(
                  context,
                  (value) => setState(() => _value = value),
                ),
              ),
              if (widget.helperText != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.helperText!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: isValid
                          ? () => Navigator.of(context).pop(_value)
                          : null,
                      child: const Text('确定'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripWheelPickerViewport extends StatelessWidget {
  const _TripWheelPickerViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
