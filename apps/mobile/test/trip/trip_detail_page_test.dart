import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:savorseek/features/auth/auth_service.dart';
import 'package:savorseek/features/trip/trip_detail_page.dart';
import 'package:savorseek/features/trip/trip_mapper.dart';
import 'package:savorseek/features/trip/trip_models.dart';
import 'package:savorseek/features/trip/trip_repository.dart';
import 'package:savorseek/features/trip/trip_repository_fakes.dart';
import 'package:savorseek/features/trip/trip_time_zone.dart';

import 'trip_reschedule_test.dart' show FakeWritableRepository;

/// 二级页面：单个行程的渲染与状态分支。
void main() {
  setUpAll(TripTimeZone.ensureInitialized);

  TripPlan buildPlan() => TripMapper.planFromRow({
    'id': 'trip-1',
    'title': '杭州一日寻味',
    'timezone': 'Asia/Shanghai',
    'revision': 2,
    'trip_days': [
      {
        'id': 'day-1',
        'local_date': '2026-09-01',
        'trip_items': [
          {
            'id': 'item-1',
            'trip_day_id': 'day-1',
            'item_type': 'place_visit',
            'title': '片儿川',
            'planned_start_at': '2026-09-01T04:00:00+00:00',
            'planned_end_at': '2026-09-01T05:00:00+00:00',
            'time_slot': 'lunch',
            'position': 0,
            'status': 'planned',
            'is_time_locked': true,
          },
        ],
      },
    ],
  });

  Widget wrap(
    TripRepository repository, {
    String tripId = 'trip-1',
    AuthService? auth,
  }) => MaterialApp(
    home: TripDetailPage(repository: repository, tripId: tripId, auth: auth),
  );

  testWidgets('渲染行程标题、时间轴与地图回退', (tester) async {
    await tester.pumpWidget(wrap(InMemoryTripRepository(plan: buildPlan())));
    await tester.pumpAndSettle();

    // 标题在 AppBar 上，由本页自己提供（本页盖住了 AppShell 的主导航）。
    expect(find.text('杭州一日寻味'), findsOneWidget);
    // 一个可定位节点都没有，故说明缺的是地点而非地图能力。
    expect(find.text('还没有地点节点'), findsOneWidget);
    expect(find.text('片儿川'), findsWidgets);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('行程已不存在时提示并给出返回列表', (tester) async {
    // 读不到只可能是它没了（另一台设备删的，或列表数据已过期）。
    // 显示「暂无行程」是误导——那是列表页「你还没有行程」的文案。
    await tester.pumpWidget(
      wrap(const InMemoryTripRepository(), tripId: 'trip-missing'),
    );
    await tester.pumpAndSettle();

    expect(find.text('此行程已不存在'), findsOneWidget);
    expect(find.text('返回列表'), findsOneWidget);
    expect(find.text('暂无行程'), findsNothing);
  });

  testWidgets('不自动返回，等用户自己点', (tester) async {
    // 无预警地弹回列表，用户不知道刚才发生了什么。
    await tester.pumpWidget(
      wrap(const InMemoryTripRepository(), tripId: 'trip-missing'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TripDetailPage), findsOneWidget);
  });

  testWidgets('读取失败时给出重试', (tester) async {
    await tester.pumpWidget(wrap(_FailingRepository()));
    await tester.pumpAndSettle();

    expect(find.text('行程暂时加载失败'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });

  testWidgets('未认证时展示登录引导而非错误页', (tester) async {
    await tester.pumpWidget(
      wrap(_UnauthenticatedRepository(), auth: const UnavailableAuthService()),
    );
    await tester.pumpAndSettle();

    expect(find.text('登录后查看行程'), findsOneWidget);
    expect(find.text('行程暂时加载失败'), findsNothing);
  });

  testWidgets('会话变化时重新读取', (tester) async {
    // 行程数据是用户私有的，登出后仍留在屏幕上不合适。详情页也要订阅，
    // 否则会留下一个「详情页显示已登出用户数据」的窗口。
    final repository = _CountingRepository(buildPlan());
    final auth = _FakeAuthService();
    addTearDown(auth.dispose);
    await tester.pumpWidget(wrap(repository, auth: auth));
    await tester.pumpAndSettle();
    final before = repository.loadCount;

    auth.emit(null);
    await tester.pumpAndSettle();

    expect(repository.loadCount, greaterThan(before));
  });

  testWidgets('只读仓库不给出写入入口', (tester) async {
    await tester.pumpWidget(wrap(InMemoryTripRepository(plan: buildPlan())));
    await tester.pumpAndSettle();

    expect(find.text('添加节点'), findsNothing);
    expect(find.byTooltip('行程操作'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('可写仓库点击节点卡片进入编辑', (tester) async {
    await tester.pumpWidget(wrap(FakeWritableRepository(buildPlan())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('片儿川').last);
    await tester.pumpAndSettle();

    expect(find.text('编辑节点'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
  });

  testWidgets('编辑表单提交后调用 editTripItem', (tester) async {
    final repository = FakeWritableRepository(buildPlan());
    await tester.pumpWidget(wrap(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('片儿川').last);
    await tester.pumpAndSettle();

    // 表单以当前值预填，用户只需改动要改的部分。
    expect(find.text('编辑节点'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '节点名称'),
      '片儿川（换一家）',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final call = repository.calls.single;
    expect(call['op'], 'edit');
    expect(call['tripItemId'], 'item-1');
    expect(call['title'], '片儿川（换一家）');
    expect(call['expectedRevision'], 2);
  });
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

/// 记录 loadPlan 次数，用于验证会话变化触发重载。
class _CountingRepository implements TripRepository {
  _CountingRepository(this.plan);

  final TripPlan plan;
  int loadCount = 0;

  @override
  Future<TripPlan?> loadPlan({String? tripId}) async {
    loadCount++;
    return plan;
  }

  @override
  Future<List<TripSummary>> listTrips() async => const [];
}

/// 可手动推送会话变化的认证服务。
class _FakeAuthService implements AuthService {
  final StreamController<String?> _controller =
      StreamController<String?>.broadcast();

  void emit(String? userId) => _controller.add(userId);
  void dispose() => _controller.close();

  @override
  Stream<String?> get userIdChanges => _controller.stream;

  @override
  bool get isSignedIn => false;

  @override
  String? get currentUserId => null;

  @override
  String? get currentEmail => null;

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
}
