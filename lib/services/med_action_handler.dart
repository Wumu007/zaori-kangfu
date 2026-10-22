import 'dart:convert';

import '../state/app_state.dart';
import 'native_bridge.dart';
import '../models/medication.dart';
import 'alarm_bus.dart';
import 'medication_repository.dart';
import 'reminder_scheduler.dart';

/// 服药动作处理：已服药 / 稍后提醒 / 跳过本次
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.5.0 从 main.dart 抽出来，因为现在有**两个入口**要做同一件事：
/// ═══════════════════════════════════════════════════════════════════
/// 1. 通知栏按钮（flutter_local_notifications 的 action 回调）；
/// 2. 响铃页的大按钮（用户进页面后点）。
///
/// 两个入口落库逻辑必须完全一致，否则「通知栏点了已服药」和
/// 「响铃页点了已服药」会记出不同的结果。
///
/// 处理完成后统一做两件收尾：
/// - [AlarmBus.handle] 广播给还开着的响铃页「这条已被处理」；
/// - [NativeBridge.ringStop] 停掉循环铃声。
///   注意：原生侧是伴生对象的静态方法 —— 就算响铃页已经不在
///   前台，铃声也一定停得掉。
Future<void> handleMedAction(String payload, String actionId) async {
  if (payload.isEmpty) return;

  Map<String, dynamic> data;
  try {
    data = jsonDecode(payload) as Map<String, dynamic>;
  } catch (_) {
    return;
  }

  final String? medId = data['med'] as String?;
  final String? atRaw = data['at'] as String?;
  if (medId == null || atRaw == null) return;

  final DateTime? planned = DateTime.tryParse(atRaw);
  if (planned == null) return;

  final MedicationRepository repo = MedicationRepository.instance;

  // 点通知主体 = 打开 App 看清单，不写库；响铃页会靠 ring 标志自己弹
  if (actionId == NotificationActionIds.open || actionId.isEmpty) {
    return;
  }

  // 已有一条用户反馈时不覆盖（比如他先在 App 里打卡了，通知才被点到）
  final ({IntakeStatus status, int snoozeMinutes})? existing =
      await repo.logOf(medId, planned);
  final bool hasFeedback =
      existing != null && existing.status.hasUserFeedback;

  final int totalSnooze = existing?.snoozeMinutes ?? 0;

  if (actionId == NotificationActionIds.taken) {
    if (existing?.status == IntakeStatus.taken) return;
    await repo.log(
      medicationId: medId,
      plannedTime: planned,
      status: IntakeStatus.taken,
      source: 'notification',
      snoozeMinutes: totalSnooze,
    );
  } else if (actionId == NotificationActionIds.skip) {
    if (!hasFeedback) {
      await repo.log(
        medicationId: medId,
        plannedTime: planned,
        status: IntakeStatus.skipped,
        source: 'notification',
        snoozeMinutes: totalSnooze,
      );
    }
  } else if (actionId == NotificationActionIds.snooze) {
    final int minutes = AppState.instance.settings.snoozeMinutes;
    await repo.log(
      medicationId: medId,
      plannedTime: planned,
      status: IntakeStatus.pending,
      source: 'notification',
      snoozeCount: 1,
      snoozeMinutes: totalSnooze + minutes,
    );
    // 稍后提醒：按原计划时刻重排一条，保证三个按钮仍对应同一顿药
    await ReminderScheduler.instance.snooze(
      medicationId: medId,
      planned: planned,
      title: '该吃药了',
      body: (data['body'] as String?) ?? '别忘了吃药',
      name: (data['name'] as String?) ?? '',
      minutes: minutes,
    );
  }

  // 收尾：通知响铃页这条已被处理 + 停循环铃声
  AlarmBus.instance.handle(payload);
  await NativeBridge.ringStop();
}
