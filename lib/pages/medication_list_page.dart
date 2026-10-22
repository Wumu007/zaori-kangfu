import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';
import 'export_flow.dart';
import 'medication_edit_page.dart';

/// 药品管理页
///
/// 四种动作都摆在同一屏，不做「更多」二级菜单 —— 试用反馈里最常见的一句话是
/// 「我不知道在哪里改药」。分类只有两组：正在提醒 / 已停用（保留历史）。
///
/// [embedded] 为 true 时表示它作为底部 Tab 的内页使用：
/// 这时不显示返回箭头（Tab 页没有「上一页」），其余完全一致。
class MedicationListPage extends StatelessWidget {
  const MedicationListPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final AppState state = AppState.instance;

    return Scaffold(
      // 内嵌在 Tab 里时不能有第二个 Scaffold 的 Material 阴影层，统一白底即可
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) {
            final List<Medication> active =
                state.allMeds.where((Medication m) => m.enabled).toList();
            final List<Medication> stopped =
                state.allMeds.where((Medication m) => !m.enabled).toList();

            return Column(
              children: <Widget>[
                SimpleNavBar(
                  title: '药品管理',
                  onBack: embedded ? null : () => Navigator.of(context).pop(),
                  trailing: TextButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text(
                      '添加',
                      style: TextStyle(fontSize: AppText.caption),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.pageX,
                      4,
                      AppSpace.pageX,
                      28,
                    ),
                    children: <Widget>[
                      if (state.allMeds.isEmpty)
                        _empty(context)
                      else ...<Widget>[
                        _sectionTitle('正在提醒', '${active.length} 种'),
                        const SizedBox(height: 8),
                        if (active.isEmpty)
                          _tipCard('还没有正在提醒的药，点右上角「添加」。')
                        else
                          for (final Medication m in active) ...<Widget>[
                            _MedCard(med: m, showStop: true),
                            const SizedBox(height: 10),
                          ],
                        if (stopped.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 12),
                          _sectionTitle('已停用', '${stopped.length} 种'),
                          const SizedBox(height: 4),
                          const Text(
                            '不再提醒，但历史记录都还在记录页里。',
                            style: TextStyle(fontSize: AppText.tiny, color: AppColors.faint),
                          ),
                          const SizedBox(height: 8),
                          for (final Medication m in stopped) ...<Widget>[
                            _MedCard(med: m, showStop: false),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ],
                      const SizedBox(height: 10),
                      // 导出放在列表末尾而不是右上角：右上角已经被「添加」占了，
                      // 再塞一个图标会把「添加」挤小，而添加才是这一页的主要动作。
                      Center(
                        child: TextButton.icon(
                          onPressed: () => ExportFlow.medications(context),
                          icon: const Icon(
                            Icons.ios_share_rounded,
                            size: 16,
                            color: AppColors.sub,
                          ),
                          label: const Text(
                            '导出药品清单（表格）',
                            style: TextStyle(
                              fontSize: AppText.caption,
                              color: AppColors.sub,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: PrimaryButton(
                          label: '语音添加',
                          height: 46,
                          onPressed: () => _add(context, voiceFirst: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GhostPill(
                          label: '键盘添加',
                          icon: Icons.keyboard_alt_outlined,
                          onTap: () => _add(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String trailing) => Row(
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: AppText.bodySm,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
          const Spacer(),
          Text(
            trailing,
            style: const TextStyle(fontSize: AppText.caption, color: AppColors.muted),
          ),
        ],
      );

  Widget _tipCard(String text) => AppCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.faint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: AppText.caption,
                  height: 1.5,
                  color: AppColors.muted,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: EmptyState(
          icon: Icons.medication_outlined,
          title: '还没有药品',
          message: '用「语音添加」说一句，或用「键盘添加」逐项填写。\n'
              '添加后每天到点会收到提醒。',
        ),
      );

  Future<void> _add(BuildContext context, {bool voiceFirst = false}) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => MedicationEditPage(voiceFirst: voiceFirst),
      ),
    );
    if (saved == true) await AppState.instance.refresh();
  }
}

/// 一张药品卡：名称 + 剂量 + 频次 + 时间 + 有效期 + 操作
class _MedCard extends StatelessWidget {
  const _MedCard({required this.med, required this.showStop});

  final Medication med;

  /// 正在提醒的药才有「停用」；已停用的给「恢复」
  final bool showStop;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final int todayCount =
        med.coversDay(now) && med.enabled ? med.times.length : 0;

    return AppCard(
      child: InkWell(
        onTap: () => _edit(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          med.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.h2,
                            fontWeight: FontWeight.w600,
                            color: med.enabled ? AppColors.ink : AppColors.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${med.dosageText} · ${med.frequencyText}',
                          style: const TextStyle(
                            fontSize: AppText.caption,
                            color: AppColors.sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!med.enabled)
                    const SoftBadge(
                      text: '已停用',
                      foreground: AppColors.muted,
                      background: AppColors.surface,
                    )
                  else if (med.hasEnded)
                    const SoftBadge(
                      text: '已过期',
                      foreground: AppColors.warn,
                      background: AppColors.warnSoft,
                    )
                  else
                    SoftBadge(
                      text: '今天 $todayCount 次',
                      foreground: AppColors.primary,
                      background: AppColors.primarySoft,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _meta(Icons.schedule_rounded, med.scheduleText),
              const SizedBox(height: 5),
              _meta(
                med.isOngoing ? Icons.all_inclusive_rounded : Icons.event_rounded,
                med.periodText,
              ),
              if (med.note != null && med.note!.isNotEmpty) ...<Widget>[
                const SizedBox(height: 5),
                _meta(Icons.restaurant_rounded, med.note!),
              ],
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: () => _edit(context),
                    child: const Text('编辑', style: TextStyle(fontSize: AppText.caption)),
                  ),
                  TextButton(
                    onPressed: () => showStop
                        ? _stop(context)
                        : _resume(context),
                    child: Text(
                      showStop ? '停止提醒' : '恢复提醒',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: showStop ? AppColors.sub : AppColors.primary,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => _delete(context),
                    icon: const Icon(Icons.delete_outline_rounded,
                        size: 20, color: AppColors.danger),
                    tooltip: '删除',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: AppColors.faint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: AppText.tiny,
                height: 1.45,
                color: AppColors.muted,
              ),
            ),
          ),
        ],
      );

  Future<void> _edit(BuildContext context) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => MedicationEditPage(med: med)),
    );
    if (saved == true) await AppState.instance.refresh();
  }

  /// 停止提醒：**保留历史记录**，只是不再排新通知
  Future<void> _stop(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('停止「${med.name}」的提醒？'),
        content: const Text(
          '停止后不会再收到这个药的提醒，但它的历史服药记录会完整保留，'
          '记录页仍能查到。需要时随时可以「恢复提醒」。',
          style: TextStyle(fontSize: AppText.caption, height: 1.7, color: AppColors.sub),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('停止提醒', style: TextStyle(color: AppColors.warn)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppState.instance.stopMedication(med);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已停止提醒：${med.name}（历史记录已保留）'),
        action: SnackBarAction(
          label: '撤销',
          textColor: Colors.white,
          onPressed: () => AppState.instance.resumeMedication(med),
        ),
      ),
    );
  }

  Future<void> _resume(BuildContext context) async {
    await AppState.instance.resumeMedication(med);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已恢复提醒：${med.name}')),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除「${med.name}」'),
        content: const Text(
          '删除后不再提醒，这个药的历史服药记录也会一起清掉，无法恢复。\n\n'
          '如果只是不想再吃，建议点「停止提醒」——历史记录会保留。',
          style: TextStyle(fontSize: AppText.caption, height: 1.7, color: AppColors.sub),
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
    if (ok != true) return;
    await AppState.instance.deleteMedication(med);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除：${med.name}')),
    );
  }
}
