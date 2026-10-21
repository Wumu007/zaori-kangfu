import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';
import 'family_view_page.dart';
import 'voice_intake_page.dart';

/// 今日页（通用版）
///
/// 信息层级：还剩几次（进度条）→ 今天吃什么（时间轴）→ 语音添加（快捷入口）。
/// 相比适老稿：去掉了整屏蓝色大卡和 56px 打钩区，
/// 但打钩的点击热区仍是 44×44，色块对比度不变 —— 该有的可达性一个没少。
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
        if (!state.notificationGranted) const _PermissionBanner(),
        if (state.todayTotal > 0) _ProgressCard(state: state),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            const Text(
              '今日用药',
              style: TextStyle(
                fontSize: AppText.bodySm,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: onOpenHistory,
              child: const Text(
                '记录',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.muted),
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
        Center(
          child: GhostPill(
            label: '语音添加',
            icon: Icons.mic_none_rounded,
            onTap: () => _openVoice(context),
          ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: EmptyState(
          icon: Icons.medication_outlined,
          title: '还没有用药计划',
          message: '点下面的「语音添加」，说一句「降压药一片，早上八点」，\n我帮你把时间和提醒都设好。',
          action: GhostPill(
            label: '语音添加',
            icon: Icons.mic_none_rounded,
            onTap: () => _openVoice(context),
          ),
        ),
      );

  Future<void> _openVoice(BuildContext context) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const VoiceIntakePage()),
    );
    if (saved == true) await AppState.instance.refresh();
  }
}

/// 顶部：日期 + 家属查看 + 设置
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
                '今日 ${state.todayTotal} 次 · 已完成 ${state.todayDone} 次',
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
                ? '今天的药都吃完了'
                : '下一次 ${next.hm} · ${next.med.name} ${next.med.dosageText}',
            style: const TextStyle(fontSize: AppText.caption, color: AppColors.sub),
          ),
        ],
      ),
    );
  }
}

/// 一行药：时间 / 药名+剂量 / 打钩
class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.now});

  final DaySlot slot;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bool taken = slot.taken;
    final bool isLate = slot.overdue(now);

    return InkWell(
      onTap: () => _openSheet(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
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
                    slot.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: taken
                          ? AppColors.success
                          : isLate
                              ? AppColors.warn
                              : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            _checkButton(context),
          ],
        ),
      ),
    );
  }

  /// 打钩/撤销。视觉是 40px 圆，热区靠外层 SizedBox 撑到 44。
  Widget _checkButton(BuildContext context) {
    final bool taken = slot.taken;
    return InkResponse(
      radius: 24,
      onTap: () => _toggle(context),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: taken
                  ? AppColors.successSoft
                  : slot.overdue(now)
                      ? AppColors.warnSoft
                      : AppColors.surface,
            ),
            child: Icon(
              Icons.check_rounded,
              size: 22,
              color: taken
                  ? AppColors.success
                  : slot.overdue(now)
                      ? AppColors.warn
                      : AppColors.faint,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context) async {
    final AppState state = AppState.instance;
    if (slot.taken) {
      await state.undo(slot);
      if (!context.mounted) return;
      _toast(context, '已撤销：${slot.med.name}');
      return;
    }
    await state.markTaken(slot);
    if (!context.mounted) return;
    // 打错了能立刻改，不用去历史页翻
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已记录：${slot.med.name}'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '点错了',
          textColor: Colors.white,
          onPressed: () => state.undo(slot),
        ),
      ),
    );
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  /// 长按/点击整行 → 管理这一个药（停用、删除）
  Future<void> _openSheet(BuildContext context) async {
    final AppState state = AppState.instance;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: Text(
                  '${slot.med.name} · ${slot.med.dosageText}',
                  style: const TextStyle(
                    fontSize: AppText.h2,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
                subtitle: Text(
                  '每天 ${slot.med.times.join(' / ')}'
                  '${slot.med.note == null ? '' : ' · ${slot.med.note}'}',
                  style: const TextStyle(fontSize: AppText.caption, color: AppColors.muted),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.pause_circle_outline_rounded),
                title: const Text('停用这个药', style: TextStyle(fontSize: AppText.bodySm)),
                subtitle: const Text(
                  '停用后不再提醒，历史记录保留',
                  style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await state.saveMedication(slot.med.copyWith(enabled: false));
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                title: const Text(
                  '删除这个药',
                  style: TextStyle(fontSize: AppText.bodySm, color: AppColors.danger),
                ),
                subtitle: const Text(
                  '连同它的历史记录一起删除，不可恢复',
                  style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
                ),
                onTap: () async {
                  final bool ok = await _confirmDelete(ctx, slot.med);
                  if (!ok || !ctx.mounted) return;
                  Navigator.of(ctx).pop();
                  await state.deleteMedication(slot.med.id);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<bool> _confirmDelete(BuildContext context, Medication med) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除「${med.name}」'),
        content: const Text(
          '删除后不再提醒，之前的服药记录也会一起清掉，无法恢复。',
          style: TextStyle(fontSize: AppText.caption, height: 1.6, color: AppColors.sub),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// 通知权限缺失提示条
class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warnSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.notifications_off_outlined, size: 18, color: AppColors.warn),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '通知权限没打开，到点可能不会提醒。请到系统设置里允许「通知」和「闹钟与提醒」。',
              style: TextStyle(
                fontSize: AppText.tiny,
                height: 1.5,
                color: AppColors.warn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
