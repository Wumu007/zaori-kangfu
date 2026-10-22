import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app.dart';
import 'models/medication.dart';
import 'services/medication_repository.dart';
import 'services/reminder_scheduler.dart';
import 'state/app_state.dart';

/// 启动流程（顺序不能改）
///
/// 1. 初始化通知插件 —— 必须先于 runApp，否则冷启动点通知按钮会丢事件；
/// 2. 申请通知 / 精确闹钟权限 —— 结果写进 AppState，首页据此显示提示条；
/// 3. 读设置 + 读数据库 —— AppState.bootstrap；
/// 4. 重建一次通知 —— 覆盖「用户改了系统时间 / 重装后权限恢复 / 长期用药
///    的 30 天排期窗口快用完」这类情况。只排不取消，已排的会被同 id 覆盖。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ReminderScheduler.instance.init(onAction: _handleNotificationAction);

  // 启动时**不申请**，只查询真实状态：通知没开就在首页顶部挂一条提示条，
  // 由用户自己点过去开。冷启动直接弹系统授权框（尤其精确闹钟那个会跳设置页）
  // 会让人以为 App 坏了 —— 而且用户还没看到任何界面就被要求授权。
  final PermissionReport report =
      await ReminderScheduler.instance.checkPermissions();
  AppState.instance.setNotificationGranted(report.allGood);

  await AppState.instance.bootstrap();
  await ReminderScheduler.instance
      .scheduleAll(await MedicationRepository.instance.activeMedications());

  // 文件读写权限（V1.3 用户要求：安装/启动时申请一次）。
  // 只影响 Android 10 及以下的旧式存储；11+ 的系统「保存到」走 SAF 不需要它。
  // 申请失败不阻塞启动 —— 导出还有应用专属目录兜底。
  try {
    await Permission.storage.request();
  } catch (_) {}

  runApp(const MedReminderApp());
}

/// 通知按钮回调：已服药 / 稍后提醒 / 跳过本次
///
/// 注意 payload 里的 `at` 是**计划时刻**，不是「现在」——
/// 用户 20:05 才点 20:00 那条通知的「已服药」，记的必须是 20:00 那一顿，
/// 否则他今天的清单里会凭空多出一顿、原来那顿变成「逾期未确认」。
///
/// Android 侧三个按钮都配置了 showsUserInterface: true，
/// 会把 App 拉到前台再回调，避免后台 isolate 里写 sqflite 的不确定性
/// （国产 ROM 上后台 isolate 被杀的概率不低）。
Future<void> _handleNotificationAction(String payload, String actionId) async {
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

  final AppState state = AppState.instance;
  final MedicationRepository repo = MedicationRepository.instance;

  // 点通知主体 = 打开 App 看清单，什么都不写
  if (actionId == NotificationActionIds.open || actionId.isEmpty) {
    await state.refresh();
    return;
  }

  // 已有一条用户反馈时不覆盖（比如他先在 App 里打卡了，通知才被点到）
  final ({IntakeStatus status, int snoozeMinutes})? existing =
      await repo.logOf(medId, planned);
  final bool hasFeedback =
      existing != null && existing.status.hasUserFeedback;

  final int totalSnooze = existing?.snoozeMinutes ?? 0;

  if (actionId == NotificationActionIds.taken) {
    if (existing?.status == IntakeStatus.taken) {
      await state.refresh();
      return;
    }
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
    final int minutes = state.settings.snoozeMinutes;
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

  // 界面立刻反映最新状态
  await state.refresh();
}
