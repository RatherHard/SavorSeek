import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/explore/agent_command_bar.dart';
import 'package:savorseek/features/explore/explore_page.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/places/place_search_query.dart';

class StubPlaceRepository implements PlaceRepository {
  final calls = <String>[];

  @override
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  }) async {
    calls.add('keywords:$keywords');
    return const PlaceSearchResult(places: [], fromCache: false);
  }

  @override
  Future<PlaceSearchResult> search(PlaceSearchQuery query) async {
    calls.add('structured');
    return const PlaceSearchResult(places: [], fromCache: false);
  }

  @override
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters = 3000,
    String? keywords,
  }) async {
    calls.add('around');
    return const PlaceSearchResult(places: [], fromCache: false);
  }
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('Explore does not enable direct search without Agent', (
    tester,
  ) async {
    final repository = StubPlaceRepository();
    await tester.pumpWidget(wrap(ExplorePage(placeRepository: repository)));

    await tester.enterText(find.byType(TextField), '烧烤');
    await tester.pump();

    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    expect(repository.calls, isEmpty);
  });

  testWidgets(
    'Explore keeps the command bar when direct search is unavailable',
    (tester) async {
      await tester.pumpWidget(wrap(const ExplorePage()));

      expect(find.byType(AgentCommandBar), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    },
  );
}
