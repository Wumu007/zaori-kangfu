import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/day_slot.dart';
import '../state/app_state.dart';
import 'app_log.dart';
import 'native_bridge.dart';

/// 应用内到点自检（V1.16.0）
///
/// ═══════════════════════════════════════════════════════════════════
/// 为什么系统闹钟不够用（用户第 9 份日志）
/// ═══════════════════════════════════════════════════════════════════
///
/// 日志里三次「测试提醒（10 秒）」，实际响的时间是：
///   15:00:23 排 → 15:00:54 响   延迟 31 秒
///   15:01:01 排 → 15:01:11 响   延迟 10 秒（准）
///   15:01:19 排 → 15:01:41 响   延迟 22 秒
///
/// 同一台手机、同一段代码，延迟忽长忽短 —— 这是**系统在延后我们的
/// 精确闹钟**，不是排程写错。日志同时给出旁证：
/// `电池白名单=false`。vivo 对没进白名单的第三方应用会做闹钟对齐/延后，
/// 应用层无法命令它准时，只能**不依赖它守时**。
///
/// 所以加这一层：只要 App 进程还活着（我们有前台服务保活），
/// 就每 15 秒自己核对一次「有没有到点但还没处理的药」，
/// 到点就直接响铃 + 弹页。系统闹钟准时就它先响，不准时就由这里兜底。
///
/// 边界：
/// - 只在 [planned, planned+10min] 窗口内触发，不会把早上的药在中午翻出来；
/// - 已经有记录（吃了 / 跳过 / 延后中）的一律不碰，避免和「稍后提醒」打架；
/// - 同一条（药 + 计划时刻）在一次会话里只触发一次，删记录也不会连环响。
class InAppReminderWatcher {
  InAppReminderWatcher._();
  static final InAppReminderWatcher instance = InAppReminderWatcher._();

  /// 检查间隔。15 秒是「够快」与「不浪费电」的折中：
  /// 最坏情况下比系统闹钟晚 15 秒，用户感知仍是「到点就响」。
  static const Duration _interval = Duration(seconds: 15);

  /// 到点后多久内仍算「该提醒」（超过就不再打扰）
  static const Duration _window = Duration(minutes: 10);

  /// 到点后至少等这么久才由本层接管 —— 给系统闹钟先手的机会，
  /// 避免两者同时响（双重铃声）
  static const Duration _graceForSystem = Duration(seconds: 20);

  static const String _prefsKey = 'watcher_fired_keys_v1';

  Timer? _timer;
  final Set<String> _fired = <String>{};
  bool _busy = false;

  /// 由 main.dart 注入：把某条提醒真正弹出来（响铃 + 进响铃页）
  void Function(String payload, String name)? onFire;

  Future<void> start() async {
    if (!NativeBridge.supported) return;
    await _loadFired();
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _tick());
    AppLog.instance.log(LogTag.notify, '应用内到点自检', '已启动（每 15 秒）');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final DateTime now = DateTime.now();
      final List<DaySlot> slots = AppState.instance.todaySlots;

      for (final DaySlot s in slots) {
        // 已有记录（已服药 / 已跳过 / 延后中）→ 不归这一层管
        if (s.status != null) continue;

        final Duration since = now.difference(s.planned);
        if (since < _graceForSystem) continue;      // 还没到点，或刚过点
        if (since > _window) continue;              // 太久了，不再打扰

        final String key = _keyOf(s);
        if (_fired.contains(key)) continue;

        _fired.add(key);
        _persistFired();

        final String payload = jsonEncode(<String, Object?>{
          'med': s.med.id,
          'at': s.planned.toIso8601String(),
          'name': s.med.name,
          'body': s.med.notificationBody,
          'ring': '1',
          // 注意：payload 必须与系统闹钟那条**完全一致**。
          // 原生响铃服务用 payload 去重（同一条已在响就跳过），
          // 多带一个字段会让去重失效，同一顿药响两遍。
        });

        AppLog.instance.notify(
          '应用内自检触发',
          '${s.hm} ${s.med.name}（系统闹钟晚了 ${since.inSeconds} 秒）',
        );
        onFire?.call(payload, s.med.name);
        break; // 一次只提醒一条，避免同时弹多个页面
      }
    } catch (e) {
      AppLog.instance.error('应用内自检', e);
    } finally {
      _busy = false;
    }
  }

  /// 同一条提醒的唯一键：药 + 计划时刻
  String _keyOf(DaySlot s) => '${s.med.id}@${s.planned.toIso8601String()}';

  Future<void> _loadFired() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final List<String>? list = sp.getStringList(_prefsKey);
      if (list == null) return;
      // 只保留今天的键，避免无限增长
      final String today =
          DateTime.now().toIso8601String().substring(0, 10);
      _fired
        ..clear()
        ..addAll(list.where((String k) => k.contains(today)));
    } catch (_) {}
  }

  Future<void> _persistFired() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String today =
          DateTime.now().toIso8601String().substring(0, 10);
      final List<String> keep =
          _fired.where((String k) => k.contains(today)).toList();
      await sp.setStringList(_prefsKey, keep);
    } catch (_) {}
  }
}
