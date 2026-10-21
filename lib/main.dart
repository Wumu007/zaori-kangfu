import 'dart:convert';

import 'package:flutter/material.dart';

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
/// 4. 重建一次通知 —— 覆盖「用户改了系统时间 / 重装后权限恢复」这类情况。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ReminderScheduler.instance.init(onAction: _handleNotificationAction);

  final bool granted = await ReminderScheduler.instance.requestPermissions();
  AppState.instance.setNotificationGranted(granted);

  await AppState.instance.bootstrap();
  await ReminderScheduler.instance.resync(AppState.instance.meds);

  runApp(const MedReminderApp());
}

/// 通知按钮回调：不打开 App 也能把「已服用 / 延后」落库
///
/// 注意：Android 侧这两个按钮配置了 showsUserInterface: true，
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
  final String? hm = data['hm'] as String?;
  if (medId == null || hm == null) return;

  final List<String> parts = hm.split(':');
  final DateTime now = DateTime.now();
  final DateTime planned = DateTime(
    now.year,
    now.month,
    now.day,
    int.tryParse(parts[0]) ?? 8,
    int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
  );

  if (actionId == NotificationActionIds.taken) {
    await MedicationRepository.instance.log(
      medicationId: medId,
      plannedTime: planned,
      status: IntakeStatus.taken,
      source: 'notification',
    );
  } else if (actionId == NotificationActionIds.snooze) {
    // 先记一条「已延后」，再排一次 10 分钟后的单独通知
    await MedicationRepository.instance.log(
      medicationId: medId,
      plannedTime: planned,
      status: IntakeStatus.snoozed,
      source: 'notification',
      snoozeCount: 1,
    );
    await ReminderScheduler.instance.snooze(
      medicationId: medId,
      hm: hm,
      title: '该吃药了',
      body: (data['body'] as String?) ?? '别忘了吃药',
      // 跟「我的 → 通知里延后多久」保持一致
      minutes: AppState.instance.settings.snoozeMinutes,
    );
  }

  // 界面立刻反映最新状态
  await AppState.instance.refresh();
}
