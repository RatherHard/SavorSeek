import 'package:savorseek/features/trip/trip_repository.dart';

/// Creates the dedicated trip used by a route-planning command.
abstract interface class RouteTripFactory {
  Future<TripWriteResult> createRouteTrip({required String idempotencyKey});
}

/// Adapts the trip repository's existing create RPC to Agent route planning.
class SupabaseRouteTripFactory implements RouteTripFactory {
  const SupabaseRouteTripFactory(this._repository);

  final SupabaseTripRepository _repository;

  @override
  Future<TripWriteResult> createRouteTrip({required String idempotencyKey}) {
    return _repository.createTrip(
      title: '美食路线规划',
      timezone: 'Asia/Shanghai',
      partySize: 1,
      idempotencyKey: idempotencyKey,
    );
  }
}
