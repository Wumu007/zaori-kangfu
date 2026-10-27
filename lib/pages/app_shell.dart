import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/medication_repository.dart';
import '../services/native_bridge.dart';
import '../services/reminder_scheduler.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'medication_list_page.dart';
import 'settings_page.dart';

/// 底部四 Tab 容器
///
/// 用 IndexedStack 而不是每次重建：切回来时首页的滚动位置、
/// 记录页的选中日期都还在，用户不会「一切 Tab 就迷路」。
///
/// V2 相比 V1 多了一个「药品」Tab —— 试用反馈里「改药找不到入口」
/// 排在第一位，把它提到一级导航是最直接的解决方式。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════
  // V1.5.0：回到前台时重新对齐通知排期
  // ═══════════════════════════════════════════════════════════════
  //
  // vivo/小米等 ROM 的省电策略会**静默取消**第三方 App 已排的闹钟。
  // 冷启动时 main.dart 会重建排期，但「App 一直在后台留着、只是切
  // 出去再切回来」的场景之前没人管 —— 万一排期被系统清了，就得等
  // 用户下次冷启动才补上。
  //
  // scheduleAll 只排未来时刻、同 id 覆盖，重复调用是安全的；
  // 不调 cancelAll，已排好的通知不会被误清。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _resyncSilently();
  }

  /// 上一次对齐排程的时间（V1.15.0 去抖）
  ///
  /// 用户日志里 5 分钟出现 40 多次「排程汇总 + 第二通道已排」——
  /// 每次回前台都全量重排 96 条通知、重写全部原生 alarm。
  /// 这不只是日志噪音：原生的 setAlarmClock 会被反复覆盖，
  /// 刚排好的闹钟可能正好被重写打断。3 秒内只做一次。
  DateTime? _lastResync;

  Future<void> _resyncSilently() async {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastResync;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastResync = now;
    try {
      // 1) 回前台补排一次（ROM 可能已把排期清掉）
      await ReminderScheduler.instance.scheduleAll(
          await MedicationRepository.instance.activeMedications());
      // 2) 守护服务被系统停掉的话，回前台时补启动
      //    （Android 12+ 不允许后台启动前台服务，只能在这里补）
      await NativeBridge.startGuard();
      await AppState.instance.refresh();
    } catch (_) {
      // 对齐失败不打扰用户，冷启动时还有一次机会
    }
  }

  void _go(int i) {
    if (_index == i) return;
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 底栏区域用渐变最底部的近白色，和 body 渐变自然衔接；
      // 不建议透明 + extendBody —— 内容会钻到悬浮栏底下，各页都要单独补边距。
      backgroundColor: AppColors.pageBottom,
      // V1.14.0：整页铺一层「上浅紫 → 下近白」的渐变。
      // 纯色底会让白卡片和背景贴在一起；渐变让顶部有颜色、内容区干净，
      // 也更接近参考稿的通透感。
      body: Container(
        decoration: const BoxDecoration(gradient: AppShadow.page),
        child: SafeArea(
          bottom: false,
          child: IndexedStack(
          index: _index,
          children: <Widget>[
            HomePage(
              onOpenHistory: () => _go(1),
              onOpenSettings: () => _go(3),
            ),
            const HistoryPage(),
            const _MedsTab(),
              const SettingsPage(),
            ],
          ),
        ),
      ),
      // 悬浮胶囊底栏：自带外边距与圆角，视觉上浮在页面之上
      bottomNavigationBar: _BottomBar(index: _index, onChanged: _go),
    );
  }
}

/// 药品 Tab 只是把管理页包一层 Scaffold 骨架：
/// 管理页本身带 AppBar（有「添加」按钮），这里不再重复包导航栏，
/// 只补一个 Tab 内的标题行。
class _MedsTab extends StatelessWidget {
  const _MedsTab();

  @override
  Widget build(BuildContext context) {
    return const MedicationListPage(embedded: true);
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  /// V1.4.0：全部换成 rounded 族，选中/未选中只切换同一族的两态，
  /// 不再出现「outlined 和 rounded 混用」的割裂感。
  static const List<(IconData, IconData, String)> _items =
      <(IconData, IconData, String)>[
    (AppIcons.tabToday, Icons.today_outlined, '今日'),
    (AppIcons.history, Icons.history_outlined, '记录'),
    (AppIcons.tabMeds, Icons.medication_outlined, '药品'),
    (AppIcons.tabMe, Icons.person_outline_rounded, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    // ═══════════════════════════════════════════════════════════════
    // V1.14.0：底部导航改成「悬浮胶囊」
    // ═══════════════════════════════════════════════════════════════
    //
    // 参考稿的底栏不是贴着屏幕边缘的一条通栏，而是浮在内容之上的
    // 圆角胶囊。好处有三：
    // 1. 和「柔紫 + 白卡」的整体风格一致，不会像一条生硬的横条；
    // 2. 内容可以从它下面穿过去（extendBody），页面显得更高；
    // 3. 选中项有自己的浅紫底，一眼能看出在哪一页。
    //
    // 布局逻辑（4 个 Tab、切换方式、顺序）与之前完全一致。
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: 62,
            decoration: BoxDecoration(
              color: const Color(0xF2FFFFFF),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: Colors.white, width: 1),
              boxShadow: AppShadow.float,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: <Widget>[
                for (int i = 0; i < _items.length; i++)
                  Expanded(child: _tab(context, i)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int i) {
    final bool on = index == i;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          // 选中项：浅紫胶囊底，比只改图标颜色更容易被看到
          color: on ? AppColors.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              on ? _items[i].$1 : _items[i].$2,
              size: 22,
              color: on ? AppColors.primary : AppColors.faint,
            ),
            const SizedBox(height: 3),
            Text(
              _items[i].$3,
              maxLines: 1,
              style: TextStyle(
                fontSize: AppText.tab,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                color: on ? AppColors.primary : AppColors.faint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
