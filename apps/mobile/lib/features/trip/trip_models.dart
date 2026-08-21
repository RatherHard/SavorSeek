import 'package:flutter/foundation.dart';

enum TripStopType { breakfast, lunch, dinner, snack, activity, rest }

enum TripMapState { available, unavailable }

@immutable
class TripStop {
  const TripStop({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.startAt,
    required this.endAt,
    required this.type,
    this.note,
    this.isLocked = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final DateTime startAt;
  final DateTime endAt;
  final TripStopType type;
  final String? note;
  final bool isLocked;

  TripStop copyWith({
    String? id,
    String? title,
    String? subtitle,
    DateTime? startAt,
    DateTime? endAt,
    TripStopType? type,
    String? note,
    bool? isLocked,
  }) {
    return TripStop(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      type: type ?? this.type,
      note: note ?? this.note,
      isLocked: isLocked ?? this.isLocked,
    );
  }
}

@immutable
class TripDay {
  TripDay({
    required this.date,
    required this.label,
    required List<TripStop> stops,
  }) : stops = List.unmodifiable(stops);

  final DateTime date;
  final String label;
  final List<TripStop> stops;

  TripDay copyWith({DateTime? date, String? label, List<TripStop>? stops}) {
    return TripDay(
      date: date ?? this.date,
      label: label ?? this.label,
      stops: stops ?? this.stops,
    );
  }
}

@immutable
class TripPlan {
  TripPlan({
    required this.id,
    required this.title,
    required this.destination,
    required List<TripDay> days,
    this.mapState = TripMapState.unavailable,
    this.updatedAt,
  }) : days = List.unmodifiable(days);

  final String id;
  final String title;
  final String destination;
  final List<TripDay> days;
  final TripMapState mapState;
  final DateTime? updatedAt;

  int get stopCount => days.fold(0, (count, day) => count + day.stops.length);

  TripPlan copyWith({
    String? id,
    String? title,
    String? destination,
    List<TripDay>? days,
    TripMapState? mapState,
    DateTime? updatedAt,
  }) {
    return TripPlan(
      id: id ?? this.id,
      title: title ?? this.title,
      destination: destination ?? this.destination,
      days: days ?? this.days,
      mapState: mapState ?? this.mapState,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
