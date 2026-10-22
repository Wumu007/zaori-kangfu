import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';
import 'family_view_page.dart';
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
        if (!state.notificationGranted) const PermissionBanner(),
        if (state.todayTotal > 0) _ProgressCard(state: state),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            const Text(
              '今日服药清单',
              style: TextStyle(
                fontSize: AppText.bodySm,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: onOpenHistory,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Text(
                  '记录 ›',
                  style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (slots.isEmpty)
          _empty(context)
        else
          AppCard(
            child: Column(
              children: <Widget>[
                for (int i = 0; i < slots.length; i++) ...<Widget>[
                  if (i > 0) const AppDivider(),
                  _SlotTile(slot: slots[i], now: now),
                ],
              ],
            ),
          ),
        const SizedBox(height: 18),
        // 唯一的语音录入入口（Bug 修复：这是全页唯一一个）
        Center(
          child: GhostPill(
            label: '语音添加药品',
            icon: Icons.mic_none_rounded,
            onTap: () => _openVoice(context),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openList(context),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
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
        padding: const EdgeInsets.only(top: 36),
        child: EmptyState(
          icon: Icons.medication_outlined,
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

/// 顶部：日期 + 药品管理 + 家属查看 + 设置
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
      padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 6, AppSpace.pageX, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '今天',
                  style: TextStyle(
                    fontSize: AppText.h1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${now.month} 月 ${now.day} 日 · ${_week[now.weekday - 1]}',
                  style: const TextStyle(
                    fontSize: AppText.caption,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          CircleIconButton(
            icon: Icons.medication_liquid_outlined,
            tooltip: '药品管理',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MedicationListPage()),
            ),
          ),
          const SizedBox(width: 8),
          CircleIconButton(
            icon: Icons.people_outline_rounded,
            tooltip: '家属查看',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FamilyViewPage()),
            ),
          ),
          const SizedBox(width: 8),
          CircleIconButton(
            icon: Icons.tune_rounded,
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
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '今日 ${state.todayTotal} 次 · 已服 ${state.todayDone} 次',
                style: const TextStyle(
                  fontSize: AppText.meta,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1B3A8B),
                ),
              ),
              const Spacer(),
              Text(
                state.todayPending == 0 ? '全部完成' : '还剩 ${state.todayPending} 次',
                style: const TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.w500,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: state.todayProgress,
              minHeight: 6,
              backgroundColor: const Color(0xFFDDE5FB),
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            next == null
                ? '剩下的药都处理过了'
                : '下一次 ${next.hm} · ${next.med.name} ${next.med.dosageText}',
            style: const TextStyle(fontSize: AppText.caption, color: AppColors.sub),
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
                    slot.med.dosageText,
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
              Icons.check_rounded,
              size: 20,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
