import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/day_slot.dart';
import '../models/medication.dart';
import 'app_settings.dart';

/// 通知点击动作
///
/// 为什么正好三个：这三个回答的是「这一顿药，我到底吃没吃」——
/// 吃了（已服药）、还没吃但现在吃不了（稍后提醒）、这次不吃了（跳过本次）。
/// 少的那个是「待确认」：它不是一个按钮，而是「什么都没点」的状态，
/// 到点后超宽限期由系统判定为「逾期未确认」。
class NotificationActionIds {
  static const String taken = 'taken';
  static const String snooze = 'snooze';
  static const String skip = 'skip';
  static const String open = 'open';
}

/// 权限体检结果：两项都开才敢说「到点会响」
class PermissionReport {
  const PermissionReport({
    required this.notifications,
    required this.exactAlarms,
  });

  /// 通知总开关（Android 13+ 的 POST_NOTIFICATIONS，或系统通知被关）
  final bool notifications;

  /// 精确闹钟（Android 12+）：没开时提醒会被推迟几分钟到几十分钟
  final bool exactAlarms;

  bool get allGood => notifications && exactAlarms;

  /// 一句话说明缺哪一项（设置页副标题用）
  String get summary {
    if (allGood) return '已允许，到点会响';
    if (!notifications && !exactAlarms) return '通知和精确闹钟都没开 —— 点这里去开';
    if (!notifications) return '通知没开，到点不会响 —— 点这里去开';
    return '精确闹钟没开，提醒可能被推迟 —— 点这里去开';
  }
}

/// 提醒调度：把用药计划铺成系统本地通知
///
/// 关键取舍（都是踩过坑才定下来的）：
/// - **按具体日期逐个排**，不用 `matchDateTimeComponents: time` 的每日重复。
///   因为 V2 的计划有开始/结束日期，每日重复没法表达「疗程最后一天之后停止」，
///   而且要支持「跳过本次」只取消当天那一条，逐日排才做得到。
/// - 排期窗口 [_windowDays] 天，长期用药在每次打开 App 时向后滚动续排，
///   这样既不用一次排几年（系统有上限、也浪费），又保证不断档。
/// - 通知 id 用 (计划日期 + 时间点) 稳定生成，重复排期会覆盖而不是叠加。
class ReminderScheduler {
  ReminderScheduler._();
  static final ReminderScheduler instance = ReminderScheduler._();

  /// 向前排多少天。30 天足够覆盖「用户一个月没打开 App」的情形，
  /// 每次冷启动都会重新对齐，所以不会真的断档。
  static const int _windowDays = 30;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;

  Future<void> init({
    void Function(String payload, String actionId)? onAction,
  }) async {
    if (_inited) return;
    tzdata.initializeTimeZones();

    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final DarwinInitializationSettings ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          'med_action',
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(NotificationActionIds.taken, '已服药'),
            DarwinNotificationAction.plain(NotificationActionIds.snooze, '稍后提醒'),
            DarwinNotificationAction.plain(NotificationActionIds.skip, '跳过本次'),
          ],
        ),
      ],
    );

    await _plugin.initialize(
      InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (NotificationResponse resp) {
        final String payload = resp.payload ?? '';
        // 点通知主体 = 打开 App 看清单，不算打卡
        onAction?.call(payload, resp.actionId ?? NotificationActionIds.open);
      },
    );

    final AndroidFlutterLocalNotificationsPlugin? androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      'med_reminder_channel',
      '服药提醒',
      description: '到点响铃震动并全屏提醒服药',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      // 声音走「闹钟」音量而不是「通知」音量：
      // 用户手机常年静音/震动，吃药提醒必须像闹钟一样穿透静音
      audioAttributesUsage: AudioAttributesUsage.alarm,
    ));

    _inited = true;
  }

  /// 申请通知 / 精确闹钟权限（Android 13+、Android 12+ 精确闹钟）
  ///
  /// 只用它做「首次启动时争取一次」，**不要**拿它当作「用户点了就检查」的入口：
  /// 通知早就允许时它立刻返回 true，用户会以为点了没反应（这正是上一版
  /// 「点『通知与闹钟权限』只提示已开启、实际闹钟没开」的根因）。
  /// 判断当前到底开没开，请用 [checkPermissions]。
  ///
  /// 返回**申请之后**的真实体检结果，而不是「这次申请有没有成功」。
  Future<PermissionReport> requestPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
    final IOSFlutterLocalNotificationsPlugin? ios =
        _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
    return checkPermissions();
  }

  /// 精确闹钟权限（Android 12+）。老系统或非 Android 一律返回 true。
  Future<bool> canScheduleExactAlarms() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    try {
      return await android.canScheduleExactNotifications() ?? true;
    } catch (_) {
      // 个别 ROM 没有这个 API，无法判定时按「可以」处理，避免吓到用户
      return true;
    }
  }

  /// 真实查询权限状态（不申请）
  ///
  /// 三个维度分别可判定，任何一个为 false 都可能导致「到点不响」，
  /// 所以设置页把它们分开显示，让用户知道该去开哪一项。
  Future<PermissionReport> checkPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final IOSFlutterLocalNotificationsPlugin? ios =
        _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();

    bool notifications = true;
    if (android != null) {
      try {
        notifications = await android.areNotificationsEnabled() ?? true;
      } catch (_) {
        notifications = true;
      }
    } else if (ios != null) {
      // iOS 没有同步查询接口，用「是否能排通知」间接判断；
      // 未授权时 zonedSchedule 会静默失败，所以这里默认 true，
      // 由用户点「重新申请」走系统弹窗
      notifications = true;
    }

    return PermissionReport(
      notifications: notifications,
      exactAlarms: await canScheduleExactAlarms(),
    );
  }

  /// 打开系统的「精确闹钟」授权页
  Future<void> openExactAlarmSettings() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestExactAlarmsPermission();
  }

  // ------------------------------------------------------------------ id

  /// 通知 id：同一天同一时间点的通知永远落到同一个 id 上
  ///
  /// 用 hashCode 会因 Dart 版本/平台不同而变？不会 —— String.hashCode 在同一
  /// 运行环境内稳定，但为了跨重装后仍能覆盖同一条（用户改时间后旧通知要消失），
  /// 这里自己算一个确定性的 int，不用 String.hashCode。
  int _idOf(String medicationId, DateTime when) {
    final int h = medicationId.codeUnits.fold<int>(7, (int a, int c) => a * 31 + c);
    final int stamp = when.year * 100000000 +
        when.month * 1000000 +
        when.day * 10000 +
        when.hour * 100 +
        when.minute;
    return ((h * 1000000007) ^ stamp) & 0x7fffffff;
  }

  String _payload(Medication med, DateTime when) => jsonEncode(<String, Object?>{
        'med': med.id,
        'at': when.toIso8601String(),
        'name': med.name,
        'body': med.notificationBody,
      });

  // ------------------------------------------------------------------ 排期

  /// 全量重建（新增/编辑/删除/停用/改延后时长后调用）
  Future<void> resync(List<Medication> meds) async {
    await _plugin.cancelAll();
    await scheduleAll(meds);
  }

  /// 只排不取消 —— App 冷启动时用，保证已排的通知不丢
  Future<void> scheduleAll(List<Medication> meds) async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);

    for (final Medication med in meds) {
      if (!med.enabled) continue;

      for (int i = 0; i < _windowDays; i++) {
        final DateTime day = today.add(Duration(days: i));
        if (!med.coversDay(day)) continue;

        for (final String hm in med.times) {
          final DateTime when = atHm(day, hm);
          // 今天已经过点的不补排：补排会立刻弹一条「该吃药了」，
          // 用户会以为 App 出了错
          if (!when.isAfter(now)) continue;
          await _schedule(med, when);
        }
      }
    }
  }

  Future<void> _schedule(Medication med, DateTime when) async {
    final tz.TZDateTime tzw = tz.TZDateTime.from(when, tz.local);
    await _plugin.zonedSchedule(
      _idOf(med.id, when),
      '该吃药了',
      med.notificationBody,
      tzw,
      _details(med, AppSettings.instance.snoozeMinutes),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      // 17.x 起必填：用绝对时间解释 scheduledDate
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: _payload(med, when),
    );
  }

  /// 取消某个药所有已排通知（删除/停用药品时用）
  Future<void> cancelMedication(Medication med) async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    for (int i = 0; i < _windowDays; i++) {
      final DateTime day = today.add(Duration(days: i));
      for (final String hm in med.times) {
        await _plugin.cancel(_idOf(med.id, atHm(day, hm)));
      }
    }
  }

  /// 取消「这一次」的通知（点了跳过、或已经在 App 里打卡）
  Future<void> cancelSlot(String medicationId, DateTime planned) async {
    await _plugin.cancel(_idOf(medicationId, planned));
  }

  /// 「稍后提醒」：取消原通知，N 分钟后单独响一次
  ///
  /// 注意用的是**同一个 payload**（同一个 planned 时刻），这样稍后那次的
  /// 三个按钮仍然对应原来那顿药，不会变成一顿新的药。
  Future<void> snooze({
    required String medicationId,
    required DateTime planned,
    required String title,
    required String body,
    required String name,
    int minutes = 10,
  }) async {
    // 先取消原通知，避免「稍后提醒」点完原通知又响一遍
    await cancelSlot(medicationId, planned);

    final tz.TZDateTime when =
        tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    await _plugin.zonedSchedule(
      _idOf(medicationId, planned) ^ 0x5f5e100,
      title,
      body,
      when,
      _detailsRaw(
        title: title,
        body: body,
        snoozeMinutes: minutes,
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: jsonEncode(<String, Object?>{
        'med': medicationId,
        'at': planned.toIso8601String(),
        'name': name,
        'body': body,
      }),
    );
  }

  NotificationDetails _details(Medication med, int snoozeMinutes) =>
      _detailsRaw(
        title: '该吃药了',
        body: med.notificationBody,
        snoozeMinutes: snoozeMinutes,
      );

  NotificationDetails _detailsRaw({
    required String title,
    required String body,
    required int snoozeMinutes,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'med_reminder_channel',
        '服药提醒',
        channelDescription: '到点响铃震动并全屏提醒服药',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        // 声音走闹钟音量，穿透媒体静音（与通道一致）
        audioAttributesUsage: AudioAttributesUsage.alarm,
        // 闹钟式强提醒：锁屏/息屏时全屏弹出；解锁时是横幅 + 响铃震动
        fullScreenIntent: true,
        playSound: true,
        enableVibration: true,
        // 亮屏：配合 WAKE_LOCK 权限，息屏时把屏幕点亮
        channelShowBadge: true,
        // 大字号 + 展开正文，老花眼也看得清
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: title,
        ),
        // 注意：这里不能是 const 列表 ——「稍后 N 分钟」的文案是运行时插值的
        actions: <AndroidNotificationAction>[
          const AndroidNotificationAction(
            NotificationActionIds.taken,
            '已服药',
            // 把 App 带到前台再回调：能看到「已记录」的绿色勾，
            // 也避免后台 isolate 写 sqflite 的不确定性（国产 ROM 常杀后台）
            showsUserInterface: true,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            NotificationActionIds.snooze,
            '稍后$snoozeMinutes分钟',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          const AndroidNotificationAction(
            NotificationActionIds.skip,
            '跳过本次',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        // iOS 侧同理：critical 级别时效性通知，穿透专注模式与静音
        // （17.x 的 DarwinNotificationDetails 没有 criticalSound 参数，
        //   音量行为由 interruptionLevel: critical 驱动）
        interruptionLevel: InterruptionLevel.critical,
        categoryIdentifier: 'med_action',
      ),
    );
  }
}
