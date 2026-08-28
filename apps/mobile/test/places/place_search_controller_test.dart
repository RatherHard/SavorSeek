import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/places/place_search_controller.dart';

/// 手写 fake 而非 mock：检索仓库只有两个方法，且这里需要控制「响应何时到达」
/// 来验证乱序响应，用 Completer 比配置 mock 的返回顺序清晰得多。
class FakePlaceRepository implements PlaceRepository {
  FakePlaceRepository();

  final List<String> keywordCalls = [];
  final List<
    ({double latitude, double longitude, int radiusMeters, String? keywords})
  >
  aroundCalls = [];
  PlaceSearchResult result = const PlaceSearchResult(
    places: [],
    fromCache: false,
  );
  PlaceSearchException? error;

  /// 非空时，检索会挂起直到测试显式完成它。
  Completer<void>? gate;

  @override
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  }) async {
    keywordCalls.add(keywords);
    if (gate != null) await gate!.future;
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }

  @override
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters = 3000,
    String? keywords,
  }) async {
    aroundCalls.add((
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
      keywords: keywords,
    ));
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }
}

Place buildPlace({String id = 'p1', String name = '老长春烧烤'}) {
  return Place(
    id: id,
    name: name,
    category: '餐饮服务;中餐厅;烧烤',
    address: '中山区某路 1 号',
    latitude: 38.914003,
    longitude: 121.614682,
    fetchedAt: DateTime(2026, 8, 23, 12),
  );
}

void main() {
  late FakePlaceRepository repository;
  late PlaceSearchController controller;

  setUp(() {
    repository = FakePlaceRepository();
    controller = PlaceSearchController(repository);
  });

  tearDown(() => controller.dispose());

  test('初始状态为 idle', () {
    expect(controller.state, isA<PlaceSearchIdle>());
    expect(controller.selected, isNull);
  });

  test('视野检索进入 viewport 状态并传递周边参数', () async {
    repository.result = PlaceSearchResult(
      places: [buildPlace()],
      fromCache: false,
    );

    await controller.searchAround(
      latitude: 38.914,
      longitude: 121.615,
      radiusMeters: 3200,
      queryKey: 'viewport-1',
      keywords: '烧烤',
    );

    expect(repository.aroundCalls, hasLength(1));
    expect(repository.aroundCalls.single.radiusMeters, 3200);
    expect(repository.aroundCalls.single.keywords, '烧烤');
    final state = controller.state;
    expect(state, isA<PlaceSearchLoaded>());
    expect((state as PlaceSearchLoaded).source, PlaceSearchSource.viewport);
  });

  test('视野结果优先作为地图候选但不替换关键词展示结果', () async {
    final keywordPlace = buildPlace(id: 'keyword');
    final viewportPlace = buildPlace(id: 'viewport', name: '视野地点');
    repository.result = PlaceSearchResult(
      places: [keywordPlace],
      fromCache: false,
    );
    await controller.searchByKeywords('烧烤');

    repository.result = PlaceSearchResult(
      places: [viewportPlace],
      fromCache: false,
    );
    await controller.searchAround(
      latitude: 38.914,
      longitude: 121.615,
      radiusMeters: 3000,
      queryKey: 'viewport-1',
    );

    expect(controller.visiblePlaces.single.id, 'keyword');
    expect(controller.mapPlaces.single.id, 'viewport');
  });

  test('相同视野 query key 不重复请求', () async {
    repository.result = PlaceSearchResult(
      places: [buildPlace()],
      fromCache: false,
    );

    await controller.searchAround(
      latitude: 38,
      longitude: 121,
      radiusMeters: 3000,
      queryKey: 'same',
    );
    await controller.searchAround(
      latitude: 38,
      longitude: 121,
      radiusMeters: 3000,
      queryKey: 'same',
    );

    expect(repository.aroundCalls, hasLength(1));
  });

  test('空白关键词不触发请求', () async {
    await controller.searchByKeywords('   ');

    expect(repository.keywordCalls, isEmpty);
    expect(controller.state, isA<PlaceSearchIdle>());
  });

  test('有结果时进入 loaded 并保留顺序', () async {
    repository.result = PlaceSearchResult(
      places: [
        buildPlace(id: 'a'),
        buildPlace(id: 'b', name: '渔家菜'),
      ],
      fromCache: true,
      fetchedAt: DateTime(2026, 8, 23, 12),
    );

    await controller.searchByKeywords('烧烤');

    final state = controller.state;
    expect(state, isA<PlaceSearchLoaded>());
    state as PlaceSearchLoaded;
    expect(state.places.map((place) => place.id), ['a', 'b']);
    expect(state.result.fromCache, isTrue);
  });

  test('无结果进入 empty 而非 failed', () async {
    repository.result = const PlaceSearchResult(places: [], fromCache: false);

    await controller.searchByKeywords('不存在的店');

    // 设计文档 §12：「没有符合条件的地点」必须与「数据源不可用」区分开。
    expect(controller.state, isA<PlaceSearchEmpty>());
    expect((controller.state as PlaceSearchEmpty).keywords, '不存在的店');
  });

  test('检索失败时携带 failure 分类与文案', () async {
    repository.error = const PlaceSearchException(
      '服务端未配置地点检索所需的密钥，请联系管理员。',
      failure: PlaceSearchFailure.providerKeyMissing,
    );

    await controller.searchByKeywords('烧烤');

    final state = controller.state;
    expect(state, isA<PlaceSearchFailed>());
    state as PlaceSearchFailed;
    expect(state.failure, PlaceSearchFailure.providerKeyMissing);
    expect(state.message, contains('密钥'));
  });

  test('Key 类配置错误不提供重试，配额与网络类可重试', () async {
    const cases = {
      PlaceSearchFailure.providerKeyMissing: false,
      PlaceSearchFailure.providerKeyRejected: false,
      PlaceSearchFailure.notConfigured: false,
      PlaceSearchFailure.invalidRequest: false,
      PlaceSearchFailure.providerQuotaExceeded: true,
      PlaceSearchFailure.providerUnavailable: true,
      PlaceSearchFailure.network: true,
      PlaceSearchFailure.storageFailure: true,
    };

    for (final entry in cases.entries) {
      final state = PlaceSearchFailed(
        keywords: 'x',
        message: 'm',
        failure: entry.key,
      );
      expect(
        state.isRetryable,
        entry.value,
        reason: '${entry.key} 的可重试性判定不符预期',
      );
    }
  });

  test('乱序响应不覆盖较新的检索结果', () async {
    // 第一次检索挂起，第二次立即返回；随后放行第一次。
    final firstGate = Completer<void>();
    repository.gate = firstGate;
    repository.result = PlaceSearchResult(
      places: [buildPlace(id: 'stale')],
      fromCache: false,
    );
    final first = controller.searchByKeywords('旧关键词');

    repository.gate = null;
    repository.result = PlaceSearchResult(
      places: [buildPlace(id: 'fresh')],
      fromCache: false,
    );
    await controller.searchByKeywords('新关键词');

    firstGate.complete();
    await first;

    final state = controller.state;
    expect(state, isA<PlaceSearchLoaded>());
    state as PlaceSearchLoaded;
    expect(state.keywords, '新关键词');
    expect(state.places.single.id, 'fresh');
  });

  test('选中与清除选中', () async {
    final place = buildPlace();

    controller.select(place);
    expect(controller.selected?.id, place.id);

    controller.clearSelection();
    expect(controller.selected, isNull);
  });

  test('新检索清除既有选中项', () async {
    controller.select(buildPlace());
    repository.result = PlaceSearchResult(
      places: [buildPlace(id: 'other')],
      fromCache: false,
    );

    await controller.searchByKeywords('烧烤');

    // 旧的选中项可能已不在新结果里，继续展示会让详情面板与地图标记不一致。
    expect(controller.selected, isNull);
  });

  test('retry 复用上次关键词', () async {
    repository.error = const PlaceSearchException(
      '网络异常',
      failure: PlaceSearchFailure.network,
    );
    await controller.searchByKeywords('烧烤');

    repository.error = null;
    repository.result = PlaceSearchResult(
      places: [buildPlace()],
      fromCache: false,
    );
    await controller.retry();

    expect(repository.keywordCalls, ['烧烤', '烧烤']);
    expect(controller.state, isA<PlaceSearchLoaded>());
  });

  test('idle 状态下 retry 不发请求', () async {
    await controller.retry();

    expect(repository.keywordCalls, isEmpty);
  });
}
