import 'package:flutter/material.dart';

import 'app.dart';
import 'models/medication.dart';
import 'services/app_log.dart';
import 'services/med_action_handler.dart';
import 'services/medication_repository.dart';
import 'services/native_bridge.dart';
import 'services/reminder_scheduler.dart';
import 'state/app_state.dart';

/// 启动流程（顺序不能改）
///
/// 1. 初始化通知插件 —— 必须先于 runApp，否则冷启动点通知按钮会丢事件；
/// 2. 检查通知 / 精确闹钟权限 —— 结果写进 AppState，首页据此显示提示条；
/// 3. 读设置 + 读数据库 —— AppState.bootstrap；
/// 4. 重建一次通知 —— 覆盖「用户改了系统时间 / 重装后权限恢复 / 长期用药
///    的 30 天排期窗口快用完」这类情况。只排不取消，已排的会被同 id 覆盖；
/// 5. **启动后台守护前台服务**（V1.6.0）—— 让进程在后台不被冻结，
///    已排的闹钟才不会被 ROM 清掉；
/// 6. 冷启动若来自「服药提醒」通知（payload 带 ring），直接进响铃页。
///
/// 全程写 [AppLog]：设置页「运行日志」可查看与导出，
/// 用来定位「语音为什么不行」「提醒为什么没响」这类只能靠运行时
/// 证据判断的问题。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppLog log = AppLog.instance;
  // 先把上次运行留下的日志读回内存（V1.7.0：跨启动累积，不再每次清空）
  await log.bootstrap();
  log.log(LogTag.app, '冷启动开始');

  // 必须尽早绑定原生 → Dart 的回调通道：
  // 不用语音的用户也要能收到「原生通知被点开」的事件（进响铃页）
  NativeBridge.bindAsrHandler();

  await ReminderScheduler.instance.init(onAction: _onNotificationEvent);

  // 启动时**不申请**，只查询真实状态：通知没开就在首页顶部挂一条提示条，
  // 由用户自己点过去开。冷启动直接弹系统授权框（尤其精确闹钟那个会跳设置页）
  // 会让人以为 App 坏了 —— 而且用户还没看到任何界面就被要求授权。
  final PermissionReport report =
      await ReminderScheduler.instance.checkPermissions();
  AppState.instance.setNotificationGranted(report.allGood);
  log.perm(
    '权限快照',
    '通知=${report.notifications} 精确闹钟=${report.exactAlarms} '
        '电池白名单=${await NativeBridge.isIgnoringBatteryOptimizations}',
  );

  await AppState.instance.bootstrap();

  final List<Medication> meds =
      await MedicationRepository.instance.activeMedications();
  await ReminderScheduler.instance.scheduleAll(meds);
  log.notify('启动排程完成', '在提醒药品 ${meds.length} 种');

  // 后台守护：必须在 App 处于前台时启动（Android 12+ 限制）
  final bool guard = await NativeBridge.startGuard();
  log.notify('后台守护服务', guard ? '已启动' : '启动失败或被系统拒绝');

  runApp(await _buildApp());
}

/// 组装根 Widget；同时处理「冷启动来自服药提醒通知」的场景
///
/// 两个来源都要看：
/// 1. flutter_local_notifications 的 launchDetails（通道一）；
/// 2. 原生 Intent extra（通道二，GuardAlarm 发的通知）。
Future<Widget> _buildApp() async {
  String? ringingPayload;
  try {
    final launch = await ReminderScheduler.instance.launchDetails;
    final resp = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true &&
        resp != null &&
        _isRingingPayload(resp.payload)) {
      ringingPayload = resp.payload;
      AppLog.instance.notify('冷启动来自提醒通知', '通道一（插件）');
    }
  } catch (e) {
    // 取不到冷启动信息就当普通启动
    AppLog.instance.error('读取冷启动通知', e);
  }

  // 通道二：原生通知点开时把 payload 放在 Intent extra 里
  if (ringingPayload == null) {
    try {
      final String? nativePayload = await NativeBridge.takePendingPayload();
      if (_isRingingPayload(nativePayload)) {
        ringingPayload = nativePayload;
        AppLog.instance.notify('冷启动来自原生通知', '通道二，进入响铃页');
      }
    } catch (e) {
      AppLog.instance.error('读取原生 payload', e);
    }
  }

  // 热启动：App 已在运行时点原生通知 → 原生推事件，这里取 payload 并进响铃页
  NativeBridge.ringingRequests.listen((_) async {
    try {
      final String? p = await NativeBridge.takePendingPayload();
      if (_isRingingPayload(p)) {
        AppLog.instance.notify('点开原生通知', '热启动进响铃页');
        AppNav.openRinging(p!);
      }
    } catch (_) {}
  });

  return MedReminderApp(initialRingingPayload: ringingPayload);
}

/// payload 是否是一条「该吃药了」的到点提醒（要进响铃页的）
bool _isRingingPayload(String? payload) {
  if (payload == null || payload.isEmpty) return false;
  return payload.contains('"ring":"1"') || payload.contains('"ring": "1"');
}

/// 通知事件统一入口（含冷启动时 fln 缓存的那次）
///
/// - 实打实的动作（已服药/稍后/跳过）→ [handleMedAction]（落库 + 停铃 +
///   通知响铃页自动退出）；
/// - 点通知主体（open）→ 若是到点提醒（payload 带 ring）→ 导航到响铃页；
///   否则只是打开 App 看清单，不写库。
void _onNotificationEvent(String payload, String actionId) {
  AppLog.instance.notify(
    '收到通知事件',
    'action=$actionId ring=${_isRingingPayload(payload)}',
  );

  final bool isAction = actionId == NotificationActionIds.taken ||
      actionId == NotificationActionIds.snooze ||
      actionId == NotificationActionIds.skip;

  if (isAction) {
    // 落库 + 收尾（停铃、广播给响铃页）都收在 handleMedAction 里
    handleMedAction(payload, actionId).then((_) {
      AppState.instance.refresh();
    });
    return;
  }

  // 点通知主体：到点提醒 → 响铃页；其他 → 普通打开
  if (_isRingingPayload(payload)) {
    AppNav.openRinging(payload);
  } else {
    AppState.instance.refresh();
  }
}
