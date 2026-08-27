import 'dart:ui';

import 'package:flutter/material.dart';

const double tripWheelPickerHeight = 180;
const double _tripWheelPickerEdgeHeight = 42;
const double _tripWheelPickerBlurSigma = 8;

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

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  SizedBox(
                    height: tripWheelPickerHeight,
                    child: _TripWheelPickerViewport(
                      child: widget.pickerBuilder(
                        context,
                        (value) => setState(() => _value = value),
                      ),
                    ),
                  ),
                  if (widget.helperText != null)
                    Text(
                      widget.helperText!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
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
        ),
      ),
    );
  }
}

class _TripWheelPickerViewport extends StatelessWidget {
  const _TripWheelPickerViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        _TripWheelPickerEdge(
          alignment: Alignment.topCenter,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [surface, surface.withValues(alpha: 0)],
          ),
        ),
        _TripWheelPickerEdge(
          alignment: Alignment.bottomCenter,
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [surface, surface.withValues(alpha: 0)],
          ),
        ),
      ],
    );
  }
}

class _TripWheelPickerEdge extends StatelessWidget {
  const _TripWheelPickerEdge({required this.alignment, required this.gradient});

  final Alignment alignment;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: SizedBox(
          height: _tripWheelPickerEdgeHeight,
          width: double.infinity,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: _tripWheelPickerBlurSigma,
                sigmaY: _tripWheelPickerBlurSigma,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: gradient),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
