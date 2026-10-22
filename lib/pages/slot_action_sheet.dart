import 'package:flutter/material.dart';

import '../models/day_slot.dart';
import '../models/medication.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

/// 一次的处置面板（首页点击某一行、记录页点某一条都进这里）
///
/// 三个主动作和系统通知上的三个按钮完全一致 ——
/// 用户在通知里学和在这里学的是同一套心智模型，不用记两套。
Future<void> openSlotActionSheet(BuildContext context, DaySlot slot) async {
  final AppState state = AppState.instance;
  final DateTime now = DateTime.now();
  final IntakeStatus st = slot.displayStatus(now);

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppColors.bg,
    builder: (BuildContext ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${slot.hm}  ${slot.med.name}',
                          style: const TextStyle(
                            fontSize: AppText.h2,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${slot.doseText}'
                          '${slot.med.note == null ? '' : ' · ${slot.med.note}'}'
                          ' · ${_dateText(slot.planned)}',
                          style: const TextStyle(
                            fontSize: AppText.caption,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  StatusBadge(status: st),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.check_circle_outline_rounded,
                  color: AppColors.success),
              title: const Text('已服药', style: TextStyle(fontSize: AppText.bodySm)),
              subtitle: const Text(
                '记一笔「吃了」，并取消这次提醒',
                style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                await state.markTaken(slot);
                if (!context.mounted) return;
                _toast(context, '已记录：${slot.med.name}', onUndo: () => state.undo(slot));
              },
            ),
            ListTile(
              leading: const Icon(Icons.snooze_rounded, color: AppColors.primary),
              title: Text(
                '稍后提醒（${state.settings.snoozeMinutes} 分钟后）',
                style: const TextStyle(fontSize: AppText.bodySm),
              ),
              subtitle: const Text(
                '记为「待确认」，稍后还会再提醒一次',
                style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                await state.snoozeSlot(slot);
                if (!context.mounted) return;
                _toast(context, '${state.settings.snoozeMinutes} 分钟后再次提醒');
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline_rounded,
                  color: AppColors.sub),
              title: const Text('跳过本次', style: TextStyle(fontSize: AppText.bodySm)),
              subtitle: const Text(
                '这一顿不吃了，记为「已跳过」，算未服用',
                style: TextStyle(fontSize: AppText.tiny, color: AppColors.muted),
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                if (state.settings.confirmBeforeSkip) {
                  final bool ok = await _confirmSkip(context, slot);
                  if (!ok) return;
                }
                await state.markSkipped(slot);
                if (!context.mounted) return;
                _toast(context, '已跳过这一次',
                    onUndo: () => state.undo(slot));
              },
            ),
            if (st.hasUserFeedback) ...<Widget>[
              ListTile(
                leading: const Icon(Icons.undo_rounded, color: AppColors.muted),
                title: const Text(
                  '撤销这条记录',
                  style: TextStyle(fontSize: AppText.bodySm, color: AppColors.sub),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await state.undo(slot);
                  if (!context.mounted) return;
                  _toast(context, '已撤销');
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// 单行打钩：点一下 = 已服药，再点一下 = 撤销
///
/// 为什么打钩只做「已服药 / 撤销」两态：这一列的图标是勾，
/// 勾的功能就该是「吃了」。跳过、稍后提醒是「不常规的操作」，
/// 放到点整行出来的面板里，避免误触。
Future<void> toggleTaken(BuildContext context, DaySlot slot) async {
  final AppState state = AppState.instance;
  if (slot.taken) {
    await state.undo(slot);
    if (!context.mounted) return;
    _toast(context, '已撤销：${slot.med.name}');
    return;
  }
  await state.markTaken(slot);
  if (!context.mounted) return;
  _toast(context, '已记录：${slot.med.name}', onUndo: () => state.undo(slot));
}

Future<bool> _confirmSkip(BuildContext context, DaySlot slot) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('确定跳过这一次？'),
      content: Text(
        '${slot.med.name} · ${slot.hm}\n'
        '跳过后记为「已跳过」，统计里算未服用。如果只是现在不方便，'
        '建议选「稍后提醒」。',
        style: const TextStyle(
          fontSize: AppText.caption,
          height: 1.7,
          color: AppColors.sub,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('再想想'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('跳过', style: TextStyle(color: AppColors.warn)),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 统一轻提示：2 秒自动消失（带撤销动作 4 秒），弹出前清掉旧条目。
/// 修复 V1.2「『已记录：XXX，点错了』黑条不消失」的问题。
void _toast(BuildContext context, String text, {VoidCallback? onUndo}) {
  showAppToast(context, text, onUndo: onUndo);
}

String _dateText(DateTime d) {
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(d.year, d.month, d.day);
  final int diff = today.difference(day).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff == -1) return '明天';
  return '${d.month} 月 ${d.day} 日';
}
