import 'package:flutter/material.dart';

import 'app.dart';
import 'services/med_action_handler.dart';
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
///
/// V1.5.0：冷启动若来自「服药提醒」通知（payload 带 ring 标志），
/// 直接打开响铃页 —— 锁屏上 fullScreenIntent 拉起的就是这条路径。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ReminderScheduler.instance.init(onAction: _onNotificationEvent);

  // 启动时**不申请**，只查询真实状态：通知没开就在首页顶部挂一条提示条，
  // 由用户自己点过去开。冷启动直接弹系统授权框（尤其精确闹钟那个会跳设置页）
  // 会让人以为 App 坏了 —— 而且用户还没看到任何界面就被要求授权。
  final PermissionReport report =
      await ReminderScheduler.instance.checkPermissions();
  AppState.instance.setNotificationGranted(report.allGood);

  await AppState.instance.bootstrap();

  await ReminderScheduler.instance
      .scheduleAll(await MedicationRepository.instance.activeMedications());

  runApp(await _buildApp());
}

/// 组装根 Widget；同时处理「冷启动来自服药提醒通知」的场景
Future<Widget> _buildApp() async {
  String? ringingPayload;
  try {
    final launch = await ReminderScheduler.instance.launchDetails;
    final resp = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true &&
        resp != null &&
        _isRingingPayload(resp.payload)) {
      ringingPayload = resp.payload;
    }
  } catch (_) {
    // 取不到冷启动信息就当普通启动
  }
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
