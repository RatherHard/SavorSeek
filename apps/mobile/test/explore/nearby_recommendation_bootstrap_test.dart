import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/features/agent/agent_context.dart';
import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/agent/agent_repository.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/explore/nearby_recommendation_bootstrap.dart';
import 'package:savorseek/features/location/location_service.dart';

class _SignedInAuth implements AuthService {
  final StreamController<String?> _changes =
      StreamController<String?>.broadcast();

  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentEmail => 'user@example.com';

  @override
  bool get isSignedIn => true;

  @override
  Stream<String?> get userIdChanges => _changes.stream;

  @override
  Future<void> signIn({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signUp({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signOut() async {}

  Future<void> dispose() => _changes.close();
}

class _RecordingAgentController extends AgentController {
  _RecordingAgentController(_SignedInAuth auth)
    : super(repository: const UnavailableAgentRepository(), auth: auth);

  int nearbySubmissionCount = 0;

  @override
  Future<void> submitNearbyFoodRecommendations({
    required DeviceLocation location,
    AgentSubmitContext context = const AgentSubmitContext(),
  }) async {
    nearbySubmissionCount++;
  }
}

class _PendingLocationService implements LocationService {
  final Completer<DeviceLocation> result = Completer<DeviceLocation>();
  int calls = 0;

  @override
  Future<DeviceLocation> getCurrentLocation() {
    calls++;
    return result.future;
  }
}

class _SequenceLocationService implements LocationService {
  _SequenceLocationService(this.results);

  final List<Future<DeviceLocation> Function()> results;
  int calls = 0;

  @override
  Future<DeviceLocation> getCurrentLocation() {
    final result = results[calls++];
    return result();
  }
}

void main() {
  late _SignedInAuth auth;
  late _RecordingAgentController agent;

  setUp(() {
    auth = _SignedInAuth();
    agent = _RecordingAgentController(auth);
  });

  tearDown(() async {
    agent.dispose();
    await auth.dispose();
  });

  test(
    'location callback completes the nearby recommendation submission',
    () async {
      final locationService = AmapLocationService();
      final bootstrap = NearbyRecommendationBootstrap(
        locationService: locationService,
        agentController: agent,
        auth: auth,
      );
      addTearDown(bootstrap.dispose);

      final start = bootstrap.start();
      locationService.update(
        const AMapLocation(latLng: LatLng(31.2304, 121.4737)),
      );
      await start;

      expect(agent.nearbySubmissionCount, 1);
      expect(bootstrap.error, isNull);
      expect(bootstrap.isLoading, isFalse);
    },
  );

  test('concurrent starts submit to Agent only once', () async {
    final locationService = _PendingLocationService();
    final bootstrap = NearbyRecommendationBootstrap(
      locationService: locationService,
      agentController: agent,
      auth: auth,
    );
    addTearDown(bootstrap.dispose);

    final first = bootstrap.start();
    final second = bootstrap.start();
    locationService.result.complete(
      const DeviceLocation(latitude: 31.2304, longitude: 121.4737),
    );
    await Future.wait([first, second]);

    expect(locationService.calls, 1);
    expect(agent.nearbySubmissionCount, 1);
  });

  test('retry obtains location and submits after a location failure', () async {
    final locationService = _SequenceLocationService([
      () => Future<DeviceLocation>.error(
        const LocationException(
          '获取当前位置超时，请重试。',
          failure: LocationFailure.timeout,
        ),
      ),
      () async => const DeviceLocation(latitude: 31.2304, longitude: 121.4737),
    ]);
    final bootstrap = NearbyRecommendationBootstrap(
      locationService: locationService,
      agentController: agent,
      auth: auth,
    );
    addTearDown(bootstrap.dispose);

    await bootstrap.start();
    expect(bootstrap.error?.failure, LocationFailure.timeout);
    expect(agent.nearbySubmissionCount, 0);

    await bootstrap.retry();

    expect(locationService.calls, 2);
    expect(agent.nearbySubmissionCount, 1);
    expect(bootstrap.error, isNull);
    expect(bootstrap.isLoading, isFalse);
  });
}
