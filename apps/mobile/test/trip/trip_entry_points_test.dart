import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/places/place_models.dart';
import 'package:savorseek/features/places/place_repository.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_repository_fakes.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

/// 载入态下的功能入口回归测试。
///
/// 存在的意义：创建行程后「创建/添加」入口曾整体消失——唯一的创建按钮只挂在
/// 空态组件上，载入态没有任何行程级入口。这里锁住载入态必须同时具备
/// 行程级操作菜单与添加节点入口。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  Widget wrap(TripRepository repository) => MaterialApp(
    home: TripDetailPage(repository: repository, tripId: 'trip-1'),
  );

  // 带两天与一个已排项的最小行程，日期与项均有真实 id，故写入入口可用。
  FakeWritableRepository buildRepository() {
    return FakeWritableRepository(
      TripMapper.planFromRow({
        'id': 'trip-1',
        'title': '大连两日寻味',
        'timezone': 'Asia/Shanghai',
        'revision': 3,
        'trip_days': [
          {
            'id': 'day-1',
            'local_date': '2026-09-01',
            'trip_items': [
              {
                'id': 'item-1',
                'trip_day_id': 'day-1',
                'item_type': 'place_visit',
                'title': '海鲜面馆',
                'planned_start_at': '2026-09-01T04:00:00+00:00',
                'planned_end_at': '2026-09-01T05:00:00+00:00',
                'time_slot': 'lunch',
                'position': 0,
                'status': 'planned',
              },
            ],
          },
          {'id': 'day-2', 'local_date': '2026-09-02', 'trip_items': []},
        ],
      }),
    );
  }

  testWidgets('载入态同时提供行程级操作菜单与添加节点入口', (tester) async {
    await tester.pumpWidget(wrap(buildRepository()));
    await tester.pumpAndSettle();

    // 行程已载入：时间表可见。标题在卡片与页头 destination 各出现一次
    // （destination 由项标题派生），故用 findsWidgets。
    expect(find.text('海鲜面馆'), findsWidgets);
    // 关键回归点：这两个入口此前在载入态完全不存在。
    expect(find.byTooltip('行程操作'), findsOneWidget);
    expect(find.text('添加节点'), findsOneWidget);
  });

  testWidgets('行程级菜单含更改时区', (tester) async {
    await tester.pumpWidget(wrap(buildRepository()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('行程操作'));
    await tester.pumpAndSettle();

    expect(find.text('更改行程时区'), findsOneWidget);
    // 新建行程需要 SupabaseTripRepository，Fake 不具备该能力，故不出现。
    // 这一条锁住「能力缺失时不给出点了报错的入口」。
    expect(find.text('新建行程'), findsNothing);
  });

  testWidgets('无写入能力时不给出添加节点与行程操作入口', (tester) async {
    await tester.pumpWidget(
      wrap(InMemoryTripRepository(plan: buildRepository().plan)),
    );
    await tester.pumpAndSettle();

    expect(find.text('海鲜面馆'), findsWidgets);
    expect(find.text('添加节点'), findsNothing);
    expect(find.byTooltip('行程操作'), findsNothing);
  });

  testWidgets('添加节点表单提交后调用 addBreakItem', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加节点'));
    await tester.pumpAndSettle();

    expect(find.text('添加行程节点'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '节点名称'), '回酒店休息');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    final call = repository.calls.single;
    expect(call['op'], 'addBreak');
    expect(call['title'], '回酒店休息');
    expect(call['tripDayId'], 'day-1');
    // 默认 12:00 起 1 小时，按 Asia/Shanghai 折算即 UTC 04:00–05:00。
    expect(call['startUtc'], '2026-09-01T04:00:00.000Z');
    expect(call['endUtc'], '2026-09-01T05:00:00.000Z');
    expect(call['timeSlot'], 'lunch');
  });

  testWidgets('节点名称为空时不提交', (tester) async {
    final repository = buildRepository();
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加节点'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(find.text('请填写节点名称'), findsOneWidget);
    expect(repository.calls, isEmpty);
  });

  group('添加地点入口', () {
    Widget wrapWithPlaces(TripRepository repository, PlaceRepository places) =>
        MaterialApp(
          home: TripDetailPage(
            repository: repository,
            tripId: 'trip-1',
            placeRepository: places,
          ),
        );

    testWidgets('未注入地点检索能力时仍只有统一添加节点入口', (tester) async {
      await tester.pumpWidget(wrap(buildRepository()));
      await tester.pumpAndSettle();

      expect(find.byTooltip('添加地点'), findsNothing);
      expect(find.text('添加节点'), findsOneWidget);
    });

    testWidgets('注入后地点搜索收进统一添加表单', (tester) async {
      await tester.pumpWidget(
        wrapWithPlaces(buildRepository(), _FakePlaceRepository()),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('添加地点'), findsNothing);
      expect(find.text('添加节点'), findsOneWidget);
    });

    testWidgets('选定地点并排期后带坐标写入', (tester) async {
      // 坐标是地图能定位这个节点的唯一来源，故断言到具体数值。
      final repository = buildRepository();
      await tester.pumpWidget(
        wrapWithPlaces(repository, _FakePlaceRepository()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加节点'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联地点（可选）'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '搜索地点',
        ),
        '海鲜',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      await tester.tap(find.text('渔家海鲜'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('确认地点'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();

      final call = repository.calls.single;
      expect(call['op'], 'addPlace');
      expect(call['placeId'], 'place-1');
      expect(call['title'], '渔家海鲜');
      expect(call['latitude'], 38.914003);
      expect(call['longitude'], 121.614682);
      // 默认 12:00 起 1 小时，按 Asia/Shanghai 折算即 UTC 04:00。
      expect(call['startUtc'], '2026-09-01T04:00:00.000Z');
    });

    testWidgets('检索失败时说明原因且不写入', (tester) async {
      final repository = buildRepository();
      await tester.pumpWidget(
        wrapWithPlaces(
          repository,
          _FakePlaceRepository(
            error: const PlaceSearchException(
              '地点检索服务暂时不可用。',
              failure: PlaceSearchFailure.providerUnavailable,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加节点'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联地点（可选）'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '搜索地点',
        ),
        '海鲜',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('地点检索服务暂时不可用。'), findsOneWidget);
      expect(repository.calls, isEmpty);
    });

    testWidgets('空结果与失败给出不同提示', (tester) async {
      // 设计文档 §12：「没有符合条件的地点」与「数据源不可用」必须可区分。
      await tester.pumpWidget(
        wrapWithPlaces(
          buildRepository(),
          _FakePlaceRepository(places: const []),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加节点'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联地点（可选）'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '搜索地点',
        ),
        '不存在的店',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.textContaining('没有找到'), findsOneWidget);
      // 空结果不是故障，给重试按钮是在暗示「再点一次可能就有了」。
      expect(find.text('重试'), findsNothing);
    });
  });
}

/// 返回固定结果的地点仓库。
class _FakePlaceRepository implements PlaceRepository {
  _FakePlaceRepository({this.places, this.error});

  /// 为空时返回一条带坐标的默认结果。
  final List<Place>? places;

  /// 非空时所有检索抛出该异常。
  final PlaceSearchException? error;

  static final _defaultPlaces = [
    Place(
      id: 'place-1',
      name: '渔家海鲜',
      category: '餐饮服务;海鲜酒楼',
      address: '大连市中山区',
      latitude: 38.914003,
      longitude: 121.614682,
      fetchedAt: DateTime.utc(2026, 8, 24),
    ),
  ];

  @override
  Future<PlaceSearchResult> searchByKeywords({
    required String keywords,
    String? city,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return PlaceSearchResult(
      places: places ?? _defaultPlaces,
      fromCache: false,
    );
  }

  @override
  Future<PlaceSearchResult> searchAround({
    required double latitude,
    required double longitude,
    int radiusMeters = 3000,
    String? keywords,
  }) => searchByKeywords(keywords: keywords ?? '');
}
