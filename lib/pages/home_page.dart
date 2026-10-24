import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../services/native_bridge.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/ui_kit.dart';
import 'medication_edit_page.dart';
import 'medication_list_page.dart';
import 'slot_action_sheet.dart';

/// 今日页
///
/// 信息层级：还剩几次（进度条）→ 今天吃什么（时间轴）→ 唯一一个语音添加入口。
///
/// 【Bug 修复记录】上一版这里有两个「语音添加」按钮：
/// 一处在列表底部（[常驻]），一处在空状态卡片里（[_empty]），
/// 而两者同时渲染时（列表为空也会渲染底部那个）就出现双入口。
/// 现在的规则是：**语音入口只由列表底部这一处负责**，空状态只给文字引导，
/// 不再放按钮 —— 单一来源，以后也不会再冒出第二个。
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.onOpenHistory,
    required this.onOpenSettings,
  });

  /// 切到「记录」Tab
  final VoidCallback onOpenHistory;

  /// 切到「我的」Tab
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        return Column(
          children: <Widget>[
            _Header(onOpenSettings: onOpenSettings),
            Expanded(
              child: state.loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : RefreshIndicator(
                      onRefresh: state.refresh,
                      child: _body(context, state),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, AppState state) {
    final DateTime now = DateTime.now();
    final List<DaySlot> slots = state.todaySlots;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.pageX,
        4,
        AppSpace.pageX,
        24,
      ),
      children: <Widget>[
        // 通知权限没拿到时，必须明说，否则用户会以为 App 坏了
        _MissBanner(onOpenSettings: onOpenSettings),
        if (state.todayTotal > 0) _ProgressCard(state: state),
        const SizedBox(height: AppSpace.gapLg),
        // V1.4.0：章节标题统一走 SectionHeader，右侧入口带小箭头图标
        SectionHeader(
          '今日服药清单',
          trailing: GestureDetector(
            onTap: onOpenHistory,
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Text(
                  '全部记录',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: AppColors.primary,
                  ),
                ),
                Icon(AppIcons.chevron, size: 15, color: AppColors.primary),
              ],
            ),
          ),
        ),
        if (slots.isEmpty)
          _empty(context)
        else
          AppCard(
            shadow: true,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < slots.length; i++) ...<Widget>[
                  if (i > 0) const AppDivider(indent: 16),
                  _SlotTile(slot: slots[i], now: now),
                ],
              ],
            ),
          ),
        const SizedBox(height: AppSpace.gapLg),
        // 唯一的语音录入入口（Bug 修复：这是全页唯一一个）
        Center(
          child: GhostPill(
            label: '语音添加药品',
            icon: AppIcons.mic,
            onTap: () => _openVoice(context),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openList(context),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Text(
                '管理我的药品',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 空状态：只给文字引导，**不放按钮**（避免与底部入口重复）
  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 28),
        child: EmptyState(
          icon: AppIcons.medication,
          title: '还没有用药计划',
          // 注意：这里刻意只放文字，不放按钮 —— 语音入口在页面底部唯一处
          message: '点下面的「语音添加药品」，说一句「降压药一片，早上八点」，\n'
              '时间和提醒一次设好；也可以进「管理我的药品」用键盘慢慢填。',
        ),
      );

  Future<void> _openVoice(BuildContext context) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const MedicationEditPage(voiceFirst: true),
      ),
    );
    if (saved == true) await AppState.instance.refresh();
  }

  Future<void> _openList(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const MedicationListPage()),
    );
  }
}

/// 顶部：日期 + 药品管理 + 设置
class _Header extends StatelessWidget {
  const _Header({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  static const List<String> _week = <String>[
    '周一', '周二', '周三', '周四', '周五', '周六', '周日',
  ];

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    return Padding(
      // V1.4.0：iOS 大标题区留白更大，标题与副标题行距更松
      padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 10, AppSpace.pageX, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '今天',
                  style: TextStyle(
                    fontSize: AppText.largeTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                    letterSpacing: -0.5, // 大字号下收紧字距，更接近 SF Pro
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${now.month} 月 ${now.day} 日 · ${_week[now.weekday - 1]}',
                  style: const TextStyle(
                    fontSize: AppText.meta,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          CircleIconButton(
            icon: AppIcons.pill,
            tooltip: '药品管理',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MedicationListPage()),
            ),
          ),
          const SizedBox(width: 8),
          CircleIconButton(
            icon: AppIcons.settings,
            tooltip: '设置',
            onTap: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

/// 进度卡：今天 3 次 · 已完成 1 次 / 还剩 2 次
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final DaySlot? next = state.nextSlot;
    final bool allDone = state.todayPending == 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // V1.4.0：从纯色块升级为渐变 + 柔和投影，
        // 更像 iOS「卡片浮在灰底上」的层次
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFFEDF2FF), Color(0xFFF6F8FF)],
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: const Color(0xFFDCE5FB), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              AppIconTile(
                allDone ? AppIcons.check : AppIcons.reminder,
                tone: allDone ? AppIconTone.green : AppIconTone.blue,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      allDone ? '今天的药都吃完了' : '还剩 ${state.todayPending} 次',
                      style: const TextStyle(
                        fontSize: AppText.bodySm,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B3A8B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '今日 ${state.todayTotal} 次 · 已服 ${state.todayDone} 次',
                      style: const TextStyle(
                        fontSize: AppText.caption,
                        color: AppColors.sub,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.todayProgress,
              minHeight: 7,
              backgroundColor: const Color(0xFFDDE5FB),
              valueColor: AlwaysStoppedAnimation<Color>(
                allDone ? AppColors.success : AppColors.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              const Icon(AppIcons.schedule, size: 14, color: AppColors.muted),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  next == null
                      ? '剩下的药都处理过了'
                      : '下一次 ${next.hm} · ${next.med.name} ${next.doseText}',
                  style: const TextStyle(
                    fontSize: AppText.caption,
                    color: AppColors.sub,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一行药：时间 / 药名+剂量+状态 / 状态徽标 / 打钩
class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.now});

  final DaySlot slot;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final IntakeStatus st = slot.displayStatus(now);
    final bool taken = st.isTaken;
    final bool overdue = st == IntakeStatus.overdue;
    final bool skipped = st == IntakeStatus.skipped;

    return InkWell(
      onTap: () => openSlotActionSheet(context, slot),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 44,
              child: Text(
                slot.hm,
                style: TextStyle(
                  fontSize: AppText.bodySm,
                  fontWeight: FontWeight.w600,
                  // 数字等宽，时间列不会左右跳
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  color: taken ? AppColors.faint : AppColors.ink,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    slot.med.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.h2,
                      fontWeight: FontWeight.w600,
                      color: taken ? AppColors.faint : AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    slot.doseText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: taken ? AppColors.faint : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusBadge(status: st, compact: true),
            const SizedBox(width: 4),
            _checkButton(context, taken: taken, overdue: overdue, skipped: skipped),
          ],
        ),
      ),
    );
  }

  /// 打钩/撤销。视觉是 36px 圆，热区靠外层 SizedBox 撑到 44。
  Widget _checkButton(
    BuildContext context, {
    required bool taken,
    required bool overdue,
    required bool skipped,
  }) {
    final Color fg = taken
        ? AppColors.success
        : overdue
            ? AppColors.warn
            : skipped
                ? AppColors.muted
                : AppColors.faint;
    final Color bg = taken
        ? AppColors.successSoft
        : overdue
            ? AppColors.warnSoft
            : AppColors.surface;
    return InkResponse(
      radius: 24,
      onTap: () => toggleTaken(context, slot),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
            child: Icon(
              AppIcons.check,
              size: 21,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// 通知权限缺失提示条
///
/// 【为什么必须有】用户装完 App 直接进首页，如果通知权限没给，
/// 到点了什么都不会响，但界面上看不出任何异常 —— 用户只会以为 App 坏了。
/// 所以这里必须显式提示，并给一个直达系统设置的按钮。
class _MissBanner extends StatefulWidget {
  const _MissBanner({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  State<_MissBanner> createState() => _MissBannerState();
}

/// 首页「后台提醒可能不响」提示条
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.6.0：从「只看通知权限」升级为「四项体检」
/// ═══════════════════════════════════════════════════════════════════
///
/// 实测反馈「只有 App 界面里能提醒」时，通知权限其实是开的 ——
/// 真正让后台提醒失效的是另外三项：电池白名单、后台守护服务、
/// 精确闹钟。这些藏在设置页里用户根本不会去翻，所以在首页显眼位置
/// 摆一条提示，把缺口逐条列出来，点一下直达设置页对应入口。
class _MissBannerState extends State<_MissBanner> with WidgetsBindingObserver {
  bool _notif = true;
  bool _battery = true;
  bool _guard = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final bool battery = await NativeBridge.isIgnoringBatteryOptimizations;
      bool guard = await NativeBridge.isGuardRunning;
      if (!guard) {
        // 回前台时补一次启动（Android 不允许后台启动前台服务）
        guard = await NativeBridge.startGuard();
      }
      if (!mounted) return;
      setState(() {
        _notif = AppState.instance.notificationGranted;
        _battery = battery;
        _guard = guard;
      });
    } catch (_) {}
  }

  List<String> get _gaps {
    final List<String> out = <String>[];
    if (!_notif) out.add('通知没打开');
    if (!_battery) out.add('没加入电池白名单');
    if (!_guard) out.add('后台守护未运行');
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final List<String> gaps = _gaps;
    if (gaps.isEmpty) return const SizedBox.shrink();

    final bool severe = !_notif;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: AppColors.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: const Color(0xFFFADFC0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              AppIcons.warning,
              size: 18,
              color: AppColors.warn,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  severe ? '通知没打开，到点不会提醒' : '后台或锁屏可能不响',
                  style: const TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warn,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${gaps.join('、')}。\n点右边去逐项开启，开关后可用「测试提醒」验证。',
                  style: const TextStyle(
                    fontSize: AppText.tiny,
                    height: 1.45,
                    color: AppColors.sub,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: widget.onOpenSettings,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: AppColors.warn,
              textStyle: const TextStyle(
                fontSize: AppText.caption,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }
}
