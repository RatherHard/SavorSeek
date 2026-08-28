import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// 只取 SupabaseClient：supabase_flutter 会导出与 Material 同名的符号。
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_list_page.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_repository_fakes.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

/// 一级页面：行程列表的四态渲染与进入详情。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  TripPlan buildPlan({String id = 'trip-1', String title = '大连寻味'}) => TripPlan(
    id: id,
    title: title,
    destination: '大连',
    days: [
      TripDay(
        id: '$id-day-1',
        date: DateTime(2026, 9, 1),
        label: '周二 · 9 月 1 日',
        stops: [
          TripStop(
            id: '$id-item-1',
            title: '海鲜面馆',
            subtitle: '午餐 · 12:00–13:00',
            startAt: DateTime(2026, 9, 1, 12),
            endAt: DateTime(2026, 9, 1, 13),
            type: TripStopType.lunch,
            tripDayId: '$id-day-1',
          ),
        ],
      ),
    ],
  );

  // 外层包 Scaffold：本页由 AppShell 的 Scaffold 承载（自身不带），
  // 提示条需要一个后代 Scaffold 才能呈现。
  Widget wrap(TripRepository repository, {AuthService? auth}) => MaterialApp(
    home: Scaffold(
      body: TripListPage(repository: repository, auth: auth),
    ),
  );

  testWidgets('无行程时给出创建引导', (tester) async {
    await tester.pumpWidget(wrap(const InMemoryTripRepository()));
    await tester.pumpAndSettle();

    expect(find.text('暂无行程'), findsOneWidget);
    expect(find.text('规划一段美食行程'), findsOneWidget);
  });

  testWidgets('列出多个行程并标注总数', (tester) async {
    await tester.pumpWidget(
      wrap(
        _MultiTripRepository([
          buildPlan(id: 'trip-a', title: '大连寻味'),
          buildPlan(id: 'trip-b', title: '东京寻味'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的行程 · 共 2 个'), findsOneWidget);
    expect(find.text('大连寻味'), findsOneWidget);
    expect(find.text('东京寻味'), findsOneWidget);
    // 日期区间与天数让用户不必进去就能分辨是哪一段。
    expect(find.textContaining('2026-09-01'), findsWidgets);
  });

  testWidgets('单个行程时不标注总数', (tester) async {
    await tester.pumpWidget(wrap(_MultiTripRepository([buildPlan()])));
    await tester.pumpAndSettle();

    expect(find.text('我的行程'), findsOneWidget);
    expect(find.textContaining('共 1 个'), findsNothing);
  });

  testWidgets('读取失败时给出重试', (tester) async {
    await tester.pumpWidget(wrap(_FailingRepository()));
    await tester.pumpAndSettle();

    expect(find.text('行程暂时加载失败'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });

  testWidgets('未认证时展示登录引导而非错误页', (tester) async {
    // RLS 下无会话读取恒为空，这不是故障，UI 必须区别对待。
    await tester.pumpWidget(
      wrap(_UnauthenticatedRepository(), auth: const UnavailableAuthService()),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录后查看行程'), findsOneWidget);
    expect(find.text('行程暂时加载失败'), findsNothing);
  });

  testWidgets('无写入能力的仓库不给出新建入口', (tester) async {
    // 创建行程只有 SupabaseTripRepository 具备；点了报错比没有入口更糟。
    // 这一条替代了原 trip_entry_points_test 中在详情页里已恒真的同名断言。
    await tester.pumpWidget(wrap(_MultiTripRepository([buildPlan()])));
    await tester.pumpAndSettle();

    expect(find.text('新建行程'), findsNothing);
  });

  testWidgets('点击卡片进入对应行程的详情页', (tester) async {
    final repository = _MultiTripRepository([
      buildPlan(id: 'trip-a', title: '大连寻味'),
      buildPlan(id: 'trip-b', title: '东京寻味'),
    ]);
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('东京寻味'));
    await tester.pumpAndSettle();

    // 进入的是点中的那一个，而不是「最近更新的那一个」。
    expect(find.byType(TripDetailPage), findsOneWidget);
    expect(repository.loadedTripIds, contains('trip-b'));
  });

  testWidgets('可写仓库给出新建入口，提交后调用 createTrip', (tester) async {
    // 新建行程从详情页页头移到了列表层面，这里锁住它确实接线了。
    final repository = _FakeSupabaseRepository([buildPlan()]);
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    expect(find.text('新建行程'), findsOneWidget);
    await tester.tap(find.text('新建行程'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '行程标题'),
      '青岛啤酒与海鲜',
    );
    await tester.tap(find.widgetWithText(FilledButton, '创建行程'));
    await tester.pumpAndSettle();

    expect(repository.createdTitles, ['青岛啤酒与海鲜']);
    expect(find.textContaining('已创建行程'), findsOneWidget);
  });

  testWidgets('创建失败时给出提示且不卡在创建中', (tester) async {
    final repository = _FakeSupabaseRepository([buildPlan()])
      ..createError = const TripRepositoryException(
        '行程已被其他操作更新，请重新加载后再试。',
        kind: TripRepositoryErrorKind.conflict,
      );
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建行程'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '行程标题'), '失败的行程');
    await tester.tap(find.widgetWithText(FilledButton, '创建行程'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请重新加载'), findsOneWidget);
    // 忙碌标志必须复位，否则一次失败后再也建不了行程。
    expect(find.text('新建行程'), findsOneWidget);
    expect(find.text('正在创建…'), findsNothing);
  });

  testWidgets('从详情页返回后重新读取列表', (tester) async {
    // 详情页里可能改了标题或删了节点，列表上的天数与更新时间都会变。
    final repository = _MultiTripRepository([buildPlan(id: 'trip-a')]);
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();
    final before = repository.listCallCount;

    await tester.tap(find.text('大连寻味'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(repository.listCallCount, greaterThan(before));
  });
}

/// 可列出多个行程的只读仓库。
class _MultiTripRepository implements TripRepository {
  _MultiTripRepository(this.plans);

  final List<TripPlan> plans;

  /// 记录被请求过的行程 id，用于验证点进的是哪一个。
  final List<String?> loadedTripIds = [];
  int listCallCount = 0;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    loadedTripIds.add(tripId);
    if (tripId == null) return plans.first;
    for (final plan in plans) {
      if (plan.id == tripId) return plan;
    }
    return null;
  }

  @override
  Future<List<TripSummary>> listTrips() async {
    listCallCount++;
    return [
      for (final plan in plans)
        TripSummary(
          id: plan.id,
          title: plan.title,
          startDate: plan.days.first.date,
          endDate: plan.days.last.date,
          timezone: plan.timezone,
        ),
    ];
  }
}

/// 具备写入能力的仓库，用于覆盖新建行程入口。
///
/// 继承 SupabaseTripRepository 而非另实现一个接口：列表页用 `is
/// SupabaseTripRepository` 判断能否创建（创建能力不在 TripWriter 接口上），
/// 只有子类才能满足这个判断。注入一个指向 localhost 的 client 即可构造，
/// 本测试从不触发真实请求——所有会走网络的方法都被覆盖了。
class _FakeSupabaseRepository extends SupabaseTripRepository {
  _FakeSupabaseRepository(this.plans)
    : super(auth: const UnavailableAuthService(), client: _offlineClient());

  /// 构造一个从不发请求的 client，并立即停掉它的令牌自动刷新。
  ///
  /// 不停掉的话 GoTrue 会起一个 10 秒周期定时器，widget 树销毁后它仍挂着，
  /// flutter_test 会以「A Timer is still pending」判定失败。
  static SupabaseClient _offlineClient() {
    final client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    client.auth.stopAutoRefresh();
    return client;
  }

  final List<TripPlan> plans;
  final List<String> createdTitles = [];
  int listCallCount = 0;

  /// 非空时创建抛出该异常。
  TripRepositoryException? createError;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    if (tripId == null) return plans.first;
    for (final plan in plans) {
      if (plan.id == tripId) return plan;
    }
    return null;
  }

  @override
  Future<List<TripSummary>> listTrips() async {
    listCallCount++;
    return [
      for (final plan in plans)
        TripSummary(
          id: plan.id,
          title: plan.title,
          startDate: plan.days.first.date,
          endDate: plan.days.last.date,
          timezone: plan.timezone,
        ),
    ];
  }

  @override
  Future<TripWriteResult> createTrip({
    required String title,
    DateTime? startDate,
    DateTime? endDate,
    String timezone = 'Asia/Shanghai',
    int partySize = 1,
    int? budgetLimitMinor,
    TripBudgetScope budgetScope = TripBudgetScope.total,
    String? idempotencyKey,
  }) async {
    createdTitles.add(title);
    final failure = createError;
    if (failure != null) throw failure;
    return const TripWriteResult(id: 'trip-new', revision: 1);
  }
}

class _FailingRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan({String? tripId}) async =>
      throw Exception('offline');

  @override
  Future<List<TripSummary>> listTrips() async => throw Exception('offline');
}

class _UnauthenticatedRepository implements TripRepository {
  @override
  Future<TripPlan?> loadPlan({String? tripId}) async =>
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );

  @override
  Future<List<TripSummary>> listTrips() async =>
      throw const TripRepositoryException(
        '登录后即可查看属于你的行程。',
        kind: TripRepositoryErrorKind.unauthenticated,
      );
}
