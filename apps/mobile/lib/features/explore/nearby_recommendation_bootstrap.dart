import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:savorseek/features/agent/agent_controller.dart';
import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/location/location_service.dart';

/// Obtains the device location once and submits the default Agent request.
class NearbyRecommendationBootstrap extends ChangeNotifier {
  NearbyRecommendationBootstrap({
    required this.locationService,
    required this.agentController,
    required this.auth,
  });

  final LocationService locationService;
  final AgentController agentController;
  final AuthService auth;
  LocationException? _error;
  bool _isLoading = false;
  bool _hasStarted = false;

  bool get isLoading => _isLoading;
  LocationException? get error => _error;

  Future<void> start() async {
    if (_hasStarted || _isLoading || !auth.isSignedIn) return;
    _hasStarted = true;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final location = await locationService.getCurrentLocation();
      await agentController.submitNearbyFoodRecommendations(location: location);
    } on LocationException catch (error) {
      _error = error;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> retry() async {
    _hasStarted = false;
    await start();
  }
}
