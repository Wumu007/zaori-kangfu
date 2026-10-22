import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';
import 'export_flow.dart';
import 'slot_action_sheet.dart';

/// 服药记录页
///
/// 结构：日期条（近 30 天可横向翻）→ 当天汇总（四个数字）→ 当天明细 → 历史统计
///
/// 明确一件事：**只有「已服药」算实际服用**。
/// 已跳过、待确认、逾期未确认都算未服用，页面上用统一的「未服用」口径说话，
/// 不玩「待确认到底算不算吃了」这种含糊表述 —— 家属看记录就是要一个明确答案。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  /// 选中的日期（只保留年月日）
  late DateTime _selected;
  late final ScrollController _stripCtrl;

  static const List<String> _week = <String>[
    '一', '二', '三', '四', '五', '六', '日',
  ];

  /// 可以往回看多少天
  static const int _historyDays = 30;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _selected = DateTime(now.year, now.month, now.day);
    // 日期条从右往左排（今天在最右），初始滚到最右
    _stripCtrl = ScrollController(initialScrollOffset: 10000);
  }

  @override
  void dispose() {
    _stripCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final DateTime now = DateTime.now();
        final DateTime today = DateTime(now.year, now.month, now.day);
        final List<DateTime> days = List<DateTime>.generate(
          _historyDays,
          (int i) => today.subtract(Duration(days: i)),
        );

        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 6, AppSpace.pageX, 8),
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
                    _isToday(_selected) ? '今天' : '${_selected.month} 月 ${_selected.day} 日',
                    style: const TextStyle(
                      fontSize: AppText.caption,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 导出口放在这里：用户看记录看到想保存的时候，视线就在这一片
                  IconButton(
                    onPressed: () => ExportFlow.records(context),
                    tooltip: '导出记录',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.ios_share_rounded,
                      size: 20,
                      color: AppColors.sub,
                    ),
                  ),
                ],
              ),
            ),
            _DateStrip(
              days: days,
              selected: _selected,
              controller: _stripCtrl,
              onSelect: (DateTime d) => setState(() => _selected = d),
              state: state,
              weekLabel: _week,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: state.loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : RefreshIndicator(
                      onRefresh: state.refresh,
                      child: _content(context, state),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _content(BuildContext context, AppState state) {
    final DateTime now = DateTime.now();
    final List<DaySlot> slots = state.slotsOf(_selected);
    final AdherenceStat stat = state.statOf(_selected);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpace.pageX, 0, AppSpace.pageX, 28),
      children: <Widget>[
        _SummaryCard(slots: slots, stat: stat, day: _selected),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Text(
              _isToday(_selected) ? '今天的计划' : '当天的计划',
              style: const TextStyle(
                fontSize: AppText.bodySm,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const Spacer(),
            if (slots.isNotEmpty)
              Text(
                '${slots.length} 次',
                style: const TextStyle(fontSize: AppText.caption, color: AppColors.muted),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (slots.isEmpty)
          AppCard(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: <Widget>[
                const Icon(Icons.event_busy_outlined, size: 20, color: AppColors.faint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _isToday(_selected)
                        ? '今天没有用药计划。到「我的 → 药品管理」添加一个吧。'
                        : '这天没有用药计划（药品可能还没开始，或已经停用/过期）。',
                    style: const TextStyle(
                      fontSize: AppText.caption,
                      height: 1.6,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          AppCard(
            child: Column(
              children: <Widget>[
                for (int i = 0; i < slots.length; i++) ...<Widget>[
                  if (i > 0) const AppDivider(),
                  _RecordRow(slot: slots[i], now: now),
                ],
              ],
            ),
          ),
        const SizedBox(height: 20),
        const Text(
          '近 7 天概览',
          style: TextStyle(
            fontSize: AppText.bodySm,
            fontWeight: FontWeight.w600,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        _WeekOverview(state: state, week: _week, today: _selected),
        const SizedBox(height: 14),
        const Text(
          '口径说明：只有「已服药」算实际服用；「已跳过」「逾期未确认」都算未服用。'
          '到点后 30 分钟内未反馈显示为「待确认」，超过 30 分钟自动记为「逾期未确认」。',
          style: TextStyle(fontSize: AppText.tiny, height: 1.6, color: AppColors.faint),
        ),
      ],
    );
  }

  static bool _isToday(DateTime d) {
    final DateTime now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }
}

/// 横向日期条：可翻近 30 天，圆点表示当天结论（绿=全服完，橙=有未服，灰=无计划）
class _DateStrip extends StatelessWidget {
  const _DateStrip({
    required this.days,
    required this.selected,
    required this.controller,
    required this.onSelect,
    required this.state,
    required this.weekLabel,
  });

  final List<DateTime> days;
  final DateTime selected;
  final ScrollController controller;
  final ValueChanged<DateTime> onSelect;
  final AppState state;
  final List<String> weekLabel;

  @override
  Widget build(BuildContext context) {
    // 日期条按时间正序（左旧右新），初始滚到右端
    final List<DateTime> ordered = days.reversed.toList();
    return SizedBox(
      height: 74,
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.pageX),
        itemCount: ordered.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int i) {
          final DateTime day = ordered[i];
          final bool active = day.year == selected.year &&
              day.month == selected.month &&
              day.day == selected.day;

          final List<DaySlot> slots = state.slotsOf(day);
          final AdherenceStat st = state.statOf(day);
          final Color dot = slots.isEmpty
              ? const Color(0xFFE3E6EB)
              : st.notTaken > 0
                  ? AppColors.warn
                  : st.pending > 0
                      ? AppColors.faint
                      : AppColors.success;

          return GestureDetector(
            onTap: () => onSelect(day),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : AppColors.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: active ? AppColors.primary : AppColors.line,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    _weekday(day, weekLabel),
                    style: TextStyle(
                      fontSize: 10,
                      color: active ? Colors.white70 : AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: AppText.bodySm,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active ? Colors.white70 : dot,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _weekday(DateTime d, List<String> weekLabel) {
    final DateTime now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) return '今天';
    return weekLabel[d.weekday - 1];
  }
}

/// 当天汇总卡：四个数字一眼看完
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.slots,
    required this.stat,
    required this.day,
  });

  final List<DaySlot> slots;
  final AdherenceStat stat;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final bool noPlan = slots.isEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: noPlan ? AppColors.surface : AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                noPlan ? '这天没有计划' : '计划 ${slots.length} 次 · 已服 ${stat.taken} 次',
                style: TextStyle(
                  fontSize: AppText.meta,
                  fontWeight: FontWeight.w600,
                  color: noPlan ? AppColors.sub : const Color(0xFF1B3A8B),
                ),
              ),
              const Spacer(),
              if (!noPlan)
                Text(
                  stat.total == 0
                      ? '还没到反馈时间'
                      : '依从 ${(stat.rate * 100).round()}%',
                  style: const TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w500,
                    color: AppColors.primary,
                  ),
                ),
            ],
          ),
          if (!noPlan) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                _metric('已服药', stat.taken, AppColors.success),
                _metric('已跳过', stat.skipped, AppColors.sub),
                _metric('待确认', stat.pending, AppColors.primary),
                _metric('逾期未确认', stat.overdue, AppColors.warn),
              ],
            ),
            if (stat.notTaken > 0) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '其中 ${stat.notTaken} 次未服用（已跳过 ${stat.skipped} + 逾期 ${stat.overdue}）',
                style: const TextStyle(fontSize: AppText.tiny, color: AppColors.warn),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _metric(String label, int value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$value',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: value == 0 ? AppColors.faint : color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

/// 记录明细行
class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.slot, required this.now});

  final DaySlot slot;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final IntakeStatus st = slot.displayStatus(now);
    final bool taken = st.isTaken;

    return InkWell(
      onTap: () => openSlotActionSheet(context, slot),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 44,
              child: Text(
                slot.hm,
                style: const TextStyle(
                  fontSize: AppText.meta,
                  fontWeight: FontWeight.w600,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  color: AppColors.ink,
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
                      fontSize: AppText.bodySm,
                      fontWeight: FontWeight.w500,
                      color: taken ? AppColors.muted : AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    slot.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // 「已服用 / 未服用」这一层必须显式写出来，不能让用户自己推
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                StatusBadge(status: st),
                const SizedBox(height: 3),
                Text(
                  taken ? '已服用' : '未服用',
                  style: TextStyle(
                    fontSize: 10,
                    color: taken ? AppColors.success : AppColors.warn,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 近 7 天概览：每天一行，讲清「几次、服了几次、未服几次」
class _WeekOverview extends StatelessWidget {
  const _WeekOverview({
    required this.state,
    required this.week,
    required this.today,
  });

  final AppState state;
  final List<String> week;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final DateTime base = DateTime(today.year, today.month, today.day);
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: List<Widget>.generate(7, (int i) {
          final DateTime day = base.subtract(Duration(days: i));
          final List<DaySlot> slots = state.slotsOf(day);
          final AdherenceStat st = state.statOf(day);
          final bool empty = slots.isEmpty;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 92,
                  child: Text(
                    i == 0
                        ? '今天 ${day.month}/${day.day}'
                        : '周${week[day.weekday - 1]} ${day.month}/${day.day}',
                    style: const TextStyle(fontSize: AppText.caption, color: AppColors.sub),
                  ),
                ),
                Expanded(
                  child: Text(
                    empty
                        ? '无计划'
                        : '计划 ${slots.length} · 已服 ${st.taken}'
                            '${st.notTaken > 0 ? ' · 未服 ${st.notTaken}' : ''}'
                            '${st.pending > 0 ? ' · 待确认 ${st.pending}' : ''}',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: empty
                          ? AppColors.faint
                          : st.notTaken > 0
                              ? AppColors.warn
                              : AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
