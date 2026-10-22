import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
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

  /// 通知渠道 id
  ///
  /// ═══════════════════════════════════════════════════════════════════
  /// V1.4.0 为什么要换 id（这是「到点只通知、不响铃」的主因之一）
  /// ═══════════════════════════════════════════════════════════════════
  ///
  /// Android 的 NotificationChannel **一旦创建就不能改**重要性、声音、
  /// 震动模式 —— `createNotificationChannel()` 对已存在的同 id 渠道
  /// 只会更新名称和描述，其余配置被系统**静默忽略**。
  ///
  /// 旧版用的是 `med_reminder_channel`。如果用户装过 V1.2/V1.3，
  /// 那个渠道在系统里已经以旧配置落地了。之后无论我们在代码里把
  /// `importance` 改成 max、把 `audioAttributesUsage` 改成 alarm，
  /// 系统都不会理会 —— 用户手机上仍然是当初那份配置。
  ///
  /// 这就是「通知能收到（渠道存在）、但不出声（旧渠道 sound/importance
  /// 不是我们要的）」的确切原因。
  ///
  /// 修复：换一个全新 id，让系统按**新配置**建档。
  /// 旧 id 留给系统自行清理（用户也可以在系统设置里手动关掉）。
  static const String _channelId = 'med_alarm_v2';

  /// 旧渠道 id：仅用于「迁移时把旧渠道上的通知清掉」
  static const String _legacyChannelId = 'med_reminder_channel';

  static const String _channelName = '服药提醒（闹钟式）';
  static const String _channelDesc = '到点像闹钟一样响铃、震动并全屏提醒服药';

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

    // 关键：建档时就把「闹钟级」配置一次性给对，
    // 因为系统之后不会再允许修改。
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.max,
      // 显式指定声音：不写 sound 时部分 ROM 会建出「无声」渠道
      playSound: true,
      sound: _alarmSound,
      enableVibration: true,
      // 明确的震动节奏：只开 enableVibration 时有些 ROM 用默认极短震动，
      // 老人感觉不到。这个节奏是「长-短-长」，接近闹钟手感。
      vibrationPattern: Int64List.fromList(<int>[0, 800, 400, 800, 400, 800]),
      enableLights: true,
      // 声音走「闹钟」音量而不是「通知」音量：
      // 用户手机常年静音/震动，吃药提醒必须像闹钟一样穿透静音
      audioAttributesUsage: AudioAttributesUsage.alarm,
      showBadge: true,
    ));

    // 清理可能存在的旧渠道（有些 ROM 允许删除自定义渠道）
    try {
      await androidImpl?.deleteNotificationChannel(_legacyChannelId);
    } catch (_) {
      // 删不掉就算了，新通知不再往旧渠道发
    }

    _inited = true;
  }

  /// 闹钟铃声
  ///
  /// 用系统的「闹钟」默认铃声 URI，而不是打包一个 mp3：
  /// 1. 不增加 APK 体积；
  /// 2. 用户如果换过系统闹钟铃声，会跟着变，符合直觉；
  /// 3. `content://settings/system/alarm_alert` 在所有 Android 版本上都存在。
  static const UriAndroidNotificationSound _alarmSound =
      UriAndroidNotificationSound('content://settings/system/alarm_alert');

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
    // Android 14+（API 34）新增：全屏通知要单独授权，
    // 不申请的话 fullScreenIntent: true 在锁屏时不会真正弹全屏，
    // 只会退化成普通横幅 —— 表现为「到点只有一条通知消息」。
    try {
      await android?.requestFullScreenIntentPermission();
    } catch (_) {
      // Android 13 及以下没有这个权限入口，忽略
    }
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
    try {
      await _plugin.zonedSchedule(
        _idOf(med.id, when),
        '该吃药了',
        med.notificationBody,
        tzw,
        _details(med, AppSettings.instance.snoozeMinutes),
        // ═══════════════════════════════════════════════════════════════
        // V1.4.0：exactAllowWhileIdle → alarmClock
        // ═══════════════════════════════════════════════════════════════
        //
        // 差别在系统 API 层：
        // - exactAllowWhileIdle 走 `setExactAndAllowWhileIdle`：
        //   精确，但**没有闹钟语义** —— 系统在深度 Doze 时仍可能
        //   把它当普通通知延后，且不会显示闹钟图标、不会走闹钟音量策略。
        // - alarmClock 走 `AlarmManagerCompat.setAlarmClock(...)`：
        //   这是真正的「闹钟」，系统会：
        //     1. 在锁屏上显示闹钟指示，保证不被 Doze 拦截；
        //     2. 走 STREAM_ALARM 音量流（配合 audioAttributesUsage: alarm）；
        //     3. 国产 ROM 的省电策略对「闹钟类」放行更宽。
        //
        // 实测「到点只有通知消息、没有铃声」的主因就是这里用了
        // exactAllowWhileIdle —— 通知到了，但系统不按闹钟处理。
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: _payload(med, when),
      );
    } on PlatformException catch (e) {
      // 精确闹钟权限被用户拒绝时插件会抛 exact_alarms_not_permitted。
      // 此时**不能放弃排期**：退到 inexactAllowWhileIdle，
      // 时间可能偏几分钟，但至少还会响 —— 比彻底不响好得多。
      if (e.code == 'exact_alarms_not_permitted') {
        _exactAlarmBlocked = true;
        try {
          await _plugin.zonedSchedule(
            _idOf(med.id, when),
            '该吃药了',
            med.notificationBody,
            tzw,
            _details(med, AppSettings.instance.snoozeMinutes),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            payload: _payload(med, when),
          );
        } catch (_) {
          // 连不精确排期都失败，只能放弃这一条
        }
      }
    } catch (_) {
      // 其他异常（时区、参数）不应打断整批排期
    }
  }

  /// 精确闹钟是否被系统拦住过（设置页据此提示用户去开）
  bool _exactAlarmBlocked = false;
  bool get exactAlarmBlocked => _exactAlarmBlocked;

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
    try {
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
        // 稍后提醒同样按闹钟排：用户点「稍后」是希望它真的再来叫一次
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: jsonEncode(<String, Object?>{
          'med': medicationId,
          'at': planned.toIso8601String(),
          'name': name,
          'body': body,
        }),
      );
    } on PlatformException catch (e) {
      if (e.code == 'exact_alarms_not_permitted') {
        _exactAlarmBlocked = true;
        // 精确闹钟被拒时退到不精确：可能偏几分钟，但比彻底不响好
        try {
          await _plugin.zonedSchedule(
            _idOf(medicationId, planned) ^ 0x5f5e100,
            title,
            body,
            when,
            _detailsRaw(title: title, body: body, snoozeMinutes: minutes),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            payload: jsonEncode(<String, Object?>{
              'med': medicationId,
              'at': planned.toIso8601String(),
              'name': name,
              'body': body,
            }),
          );
        } catch (_) {
          // 连不精确排期都失败，只能放弃这一次
        }
      }
    } catch (_) {
      // 其他异常不应把「稍后提醒」变成崩溃
    }
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
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        // 声音走闹钟音量，穿透媒体静音（与通道一致）
        audioAttributesUsage: AudioAttributesUsage.alarm,
        // 单条通知上也显式给声音，双保险：
        // 渠道配置在某些 ROM 上会被改写，通知级设置能兜住
        sound: _alarmSound,
        // 闹钟式强提醒：锁屏/息屏时全屏弹出；解锁时是横幅 + 响铃震动
        fullScreenIntent: true,
        playSound: true,
        enableVibration: true,
        // 明确的震动节奏（与渠道一致），老人更容易察觉
        vibrationPattern: Int64List.fromList(<int>[0, 800, 400, 800, 400, 800]),
        // 锁屏上也显示完整内容：吃药提醒没有隐私顾虑，
        // 而「锁屏只显示『已隐藏』」会让老人以为不是自己的药
        visibility: NotificationVisibility.public,
        // 不给自动超时：用户没处理就一直留在通知栏（到点响过就够了）
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
