import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/medication.dart';
import 'app_settings.dart';

/// 通知点击动作
class NotificationActionIds {
  static const String taken = 'taken';
  static const String snooze = 'snooze';
  static const String open = 'open';
}

/// 提醒调度：把一条用药计划铺成每天重复的本地通知
///
/// 关键取舍：
/// - 用 `matchDateTimeComponents: time` 让系统按「每天这个时刻」重复，
///   不需要自己铺未来 N 天的任务，重启后也更稳。
/// - `exactAllowWhileIdle` + 精确闹钟权限，否则国产 ROM 上会飘。
class ReminderScheduler {
  ReminderScheduler._();
  static final ReminderScheduler instance = ReminderScheduler._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;

  Future<void> init({
    void Function(String payload, String actionId)? onAction,
  }) async {
    if (_inited) return;
    tzdata.initializeTimeZones();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          'med_action',
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(NotificationActionIds.taken, '已服用'),
            DarwinNotificationAction.plain(NotificationActionIds.snooze, '延后10分钟'),
          ],
        ),
      ],
    );

    await _plugin.initialize(
      InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload ?? '';
        // 点通知主体 = 打开 App，不算打卡
        onAction?.call(payload, resp.actionId ?? NotificationActionIds.open);
      },
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'med_reminder_channel',
      '早日康复',
      description: '到点提醒服药',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));

    _inited = true;
  }

  /// 申请通知 / 精确闹钟权限（Android 13+、Android 12+ 精确闹钟）
  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission() ?? true;
    await android?.requestExactAlarmsPermission();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
    return granted;
  }

  int _idOf(String medicationId, String hm) =>
      '${medicationId}_$hm'.hashCode & 0x7fffffff;

  String _payload(Medication med, String hm) => jsonEncode({
        'med': med.id,
        'hm': hm,
        'name': med.name,
        'body': med.notificationBody,
      });

  /// 全量重建（新增/编辑/删除/停用药品后调用）
  Future<void> resync(List<Medication> meds) async {
    await _plugin.cancelAll();
    for (final med in meds.where((m) => m.enabled)) {
      await scheduleMedication(med);
    }
  }

  Future<void> scheduleMedication(Medication med) async {
    final now = tz.TZDateTime.now(tz.local);
    for (final hm in med.times) {
      final parts = hm.split(':');
      final hour = int.tryParse(parts[0]) ?? 8;
      final minute = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      var when = tz.TZDateTime(
          tz.local, now.year, now.month, now.day, hour, minute);
      if (!when.isAfter(now)) {
        when = when.add(const Duration(days: 1));
      }
      await _plugin.zonedSchedule(
        _idOf(med.id, hm),
        '该吃药了',
        med.notificationBody,
        when,
        _details(med, AppSettings.instance.snoozeMinutes),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: _payload(med, hm),
      );
    }
  }

  Future<void> cancelMedication(String medicationId, List<String> times) async {
    for (final hm in times) {
      await _plugin.cancel(_idOf(medicationId, hm));
    }
  }

  /// 通知里点「延后 10 分钟」：丢弃原通知，10 分钟后单独响一次
  Future<void> snooze({
    required String medicationId,
    required String hm,
    required String title,
    required String body,
    int minutes = 10,
  }) async {
    final when = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    await _plugin.zonedSchedule(
      _idOf(medicationId, hm) + 991,
      title,
      body,
      when,
      _details(null, minutes),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: jsonEncode({'med': medicationId, 'hm': hm}),
    );
  }

  NotificationDetails _details(Medication? med, int snoozeMinutes) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'med_reminder_channel',
        '早日康复',
        channelDescription: '到点提醒服药',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        // 大字号，老花眼也看得清
        styleInformation: BigTextStyleInformation(
          med?.notificationBody ?? '',
          contentTitle: '该吃药了',
        ),
        actions: const <AndroidNotificationAction>[
          // showsUserInterface: true —— 点「已服用」会把 App 带到前台，
          // 让老人看到「已记录」的绿色大勾，心理上更踏实；
          // 同时避免后台 isolate 写库的复杂性与不确定性。
          AndroidNotificationAction(NotificationActionIds.taken, '已服用',
              showsUserInterface: true, cancelNotification: true),
          // 延后时长跟「我的 → 通知里延后多久」联动，默认 10 分钟
          AndroidNotificationAction(NotificationActionIds.snooze, '延后$snoozeMinutes分钟',
              showsUserInterface: true, cancelNotification: true),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        categoryIdentifier: 'med_action',
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }
}
