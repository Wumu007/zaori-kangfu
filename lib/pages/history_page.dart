import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

/// 记录页
///
/// 目的只有一个：让用户（以及家属）能回答「昨天吃了吗、这周漏了几次」。
/// V1 不做图表，用「近 7 天日历条 + 按日分组的清单」表达，
/// 因为看图表要理解坐标轴，看清单不用。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  static const List<String> _week = <String>[
    '一', '二', '三', '四', '五', '六', '日',
  ];

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final DateTime now = DateTime.now();
        final DateTime today = DateTime(now.year, now.month, now.day);
        // 近 7 天（含今天），倒序展示
        final List<DateTime> days = List<DateTime>.generate(
          7,
          (int i) => today.subtract(Duration(days: i)),
        );

        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 6, AppSpace.pageX, 10),
              child: Row(
                children: <Widget>[
                  const Text(
                    '记录',
                    style: TextStyle(
                      fontSize: AppText.h1,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '近 7 天',
                    style: const TextStyle(
                      fontSize: AppText.caption,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: state.loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.pageX,
                        0,
                        AppSpace.pageX,
                        24,
                      ),
                      children: <Widget>[
                        _WeekStrip(days: days.reversed.toList(), state: state),
                        const SizedBox(height: 18),
                        ..._dayGroups(context, days, state),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 每天的「日期标题 + 明细卡」，没有计划的日期直接跳过
  List<Widget> _dayGroups(
    BuildContext context,
    List<DateTime> days,
    AppState state,
  ) {
    final List<Widget> out = <Widget>[];
    final DateTime now = DateTime.now();

    for (final DateTime day in days) {
      final List<DaySlot> slots = state.slotsOf(day);
      if (slots.isEmpty) continue;

      final int done = slots.where((DaySlot s) => s.taken).length;
      final String title = '${day.month} 月 ${day.day} 日 · 周${_week[day.weekday - 1]}';

      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(
                fontSize: AppText.caption,
                fontWeight: FontWeight.w500,
                color: AppColors.sub,
              ),
            ),
            const Spacer(),
            Text(
              '已服 $done/${slots.length}',
              style: TextStyle(
                fontSize: AppText.tiny,
                color: done == slots.length ? AppColors.success : AppColors.muted,
              ),
            ),
          ],
        ),
      ));

      out.add(AppCard(
        child: Column(
          children: <Widget>[
            for (int i = 0; i < slots.length; i++) ...<Widget>[
              if (i > 0) const AppDivider(),
              _HistoryRow(slot: slots[i], now: now),
            ],
          ],
        ),
      ));
      out.add(const SizedBox(height: 18));
    }

    if (out.isEmpty) {
      out.add(const Padding(
        padding: EdgeInsets.only(top: 60),
        child: EmptyState(
          icon: Icons.event_note_outlined,
          title: '还没有记录',
          message: '添加第一种药之后，每天的服用情况会出现在这里。',
        ),
      ));
    }
    return out;
  }
}

/// 近 7 天日历条：绿点=全服完，橙点=有漏服，灰点=当天无计划
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.days, required this.state});

  final List<DateTime> days;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    return Row(
      children: days.map((DateTime day) {
        final List<DaySlot> slots = state.slotsOf(day);
        final int done = slots.where((DaySlot s) => s.taken).length;
        final int missed = state.missedOf(day);
        final bool isToday = day.day == now.day && day.month == now.month;

        final Color dot = slots.isEmpty
            ? const Color(0xFFE3E6EB)
            : missed > 0
                ? AppColors.warn
                : done == slots.length
                    ? AppColors.success
                    : AppColors.faint;

        return Expanded(
          child: Column(
            children: <Widget>[
              Text(
                HistoryPage._week[day.weekday - 1],
                style: TextStyle(
                  fontSize: AppText.tiny,
                  color: isToday ? AppColors.primary : AppColors.muted,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isToday ? AppColors.primary : Colors.transparent,
                  border: isToday ? null : Border.all(color: AppColors.line),
                ),
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w600,
                    color: isToday ? Colors.white : AppColors.ink,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// 记录明细行
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.slot, required this.now});

  final DaySlot slot;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bool taken = slot.taken;
    final bool missed = slot.overdue(now) && !slot.taken && !slot.skipped;

    final (String label, Color fg, Color bg) = taken
        ? ('已服用', AppColors.success, AppColors.successSoft)
        : slot.skipped
            ? ('已跳过', AppColors.muted, AppColors.surface)
            : missed
                ? ('漏服', AppColors.warn, AppColors.warnSoft)
                : ('待服', AppColors.muted, AppColors.surface);

    return InkWell(
      onTap: () => _openActions(context, taken: taken),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 44,
              child: Text(
                slot.hm,
                style: TextStyle(
                  fontSize: AppText.meta,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  color: AppColors.ink,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                slot.med.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppText.bodySm,
                  fontWeight: FontWeight.w500,
                  color: AppColors.ink,
                ),
              ),
            ),
            SoftBadge(text: label, foreground: fg, background: bg),
          ],
        ),
      ),
    );
  }

  /// 记录错了要能改：撤销 / 补打卡
  Future<void> _openActions(BuildContext context, {required bool taken}) async {
    final AppState state = AppState.instance;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(
                '${slot.med.name} · ${slot.hm}',
                style: const TextStyle(
                  fontSize: AppText.h2,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
              subtitle: Text(
                '${slot.planned.month} 月 ${slot.planned.day} 日',
                style: const TextStyle(fontSize: AppText.caption, color: AppColors.muted),
              ),
            ),
            const Divider(),
            if (taken)
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: const Text('撤销这次打卡', style: TextStyle(fontSize: AppText.bodySm)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await state.undo(slot);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.check_circle_outline_rounded),
                title: const Text('补记「已服用」', style: TextStyle(fontSize: AppText.bodySm)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await state.markTaken(slot);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
