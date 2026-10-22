import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/alarm_bus.dart';
import '../services/med_action_handler.dart';
import '../services/native_bridge.dart';
import '../state/app_state.dart';
import '../services/reminder_scheduler.dart';
import '../theme/app_theme.dart';

/// 到点响铃页
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.5.0 新增 ——「铃声只响一遍就没了」的解法
/// ═══════════════════════════════════════════════════════════════════
///
/// Android 通知渠道的铃声**只播一遍**，这是系统行为，改不了。
/// 「一直响到用户处理为止」只有一个办法：到点弹一个自己的页面，
/// 页面里用 MediaPlayer 循环播放闹钟铃声 + Vibrator 循环震动。
///
/// 入口（三条路都到这）：
/// 1. 锁屏/息屏：通知 fullScreenIntent 直接全屏拉起 App（原生壳已设
///    showWhenLocked + turnScreenOn，锁屏上直接显示）；
/// 2. 解锁 + 后台：同一条 fullScreenIntent 以醒目横幅出现，点开进这里；
/// 3. App 在前台：点通知主体进这里。
///
/// 退出（三条路都停）：
/// 1. 页面按钮「已服药 / 稍后 / 跳过」→ [handleMedAction] → ringStop；
/// 2. 通知栏直接点按钮（没进页面）→ action 回调 → handleMedAction
///    → [AlarmBus] 广播 → 本页监听到自动退出；
/// 3. 用户按返回键：铃声**继续**（系统回退键不该替用户做吃药决定），
///    直到他从通知里处理或进页面处理。
class RingingPage extends StatefulWidget {
  const RingingPage({super.key, required this.payload});

  /// 原样透传的通知 payload（jsonEncode 的服药信息）
  final String payload;

  @override
  State<RingingPage> createState() => _RingingPageState();
}

class _RingingPageState extends State<RingingPage> {
  String _name = '';
  String _body = '';
  DateTime? _planned;

  @override
  void initState() {
    super.initState();
    _parse();
    // 循环响铃 + 屏幕常亮
    NativeBridge.ringStart();
    NativeBridge.keepScreenOn(true);
    // 这条已经被处理过（通知栏直接点的按钮）？→ 立即退出，不响铃
    if (AlarmBus.instance.isHandled(widget.payload)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    }
    AlarmBus.instance.handled.addListener(_onHandled);
  }

  @override
  void dispose() {
    AlarmBus.instance.handled.removeListener(_onHandled);
    NativeBridge.keepScreenOn(false);
    // 只有在这条还没被处理时才停铃（被处理时 handleMedAction 已停过）
    if (!AlarmBus.instance.isHandled(widget.payload)) {
      NativeBridge.ringStop();
    }
    super.dispose();
  }

  void _onHandled() {
    if (!mounted) return;
    if (AlarmBus.instance.isHandled(widget.payload)) _close();
  }

  void _close() {
    if (!mounted) return;
    NativeBridge.ringStop();
    Navigator.of(context).pop();
  }

  void _parse() {
    try {
      final data = jsonDecode(widget.payload) as Map<String, dynamic>;
      _name = (data['name'] as String?) ?? '';
      _body = (data['body'] as String?) ?? '';
      _planned = DateTime.tryParse(data['at'] as String? ?? '');
    } catch (_) {}
  }

  /// 三个按钮共用：处理 →（handleMedAction 内部会广播+停铃）→ 关页
  Future<void> _act(String actionId) async {
    await handleMedAction(widget.payload, actionId);
    // handleMedAction 对 open/空 action 直接 return，不广播 ——
    // 这里三个都是实打实的动作，广播一定发生，AlarmBus 会触发 _close。
    // 但保险起见（万一 payload 解析失败），这里也主动关。
    if (mounted) _close();
  }

  String get _timeText {
    final DateTime t = _planned ?? DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final int snoozeMinutes = AppState.instance.settings.snoozeMinutes;
    // 返回键可直接退出：铃声在 dispose 里停。
    // 用户没做决定时不强迫他面对响铃页，但铃声停了之后
    // 通知还留在通知栏，点开还能再进。
    return Scaffold(
        backgroundColor: const Color(0xFF101828),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.pageX),
            child: Column(
              children: <Widget>[
                const Spacer(flex: 2),
                // 顶部状态：时间 + 铃铛动画提示「正在响」
                Text(
                  _timeText,
                  style: const TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '该吃药了',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                const Spacer(flex: 2),
                // 药名大字
                Text(
                  _name.isEmpty ? '到服药时间了' : _name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.3,
                  ),
                ),
                if (_body.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    _body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: AppText.h2,
                      color: Colors.white70,
                      height: 1.5,
                    ),
                  ),
                ],
                const Spacer(flex: 3),
                // 已服药 —— 主按钮，最大
                _BigButton(
                  label: '已服药',
                  icon: Icons.check_rounded,
                  background: AppColors.success,
                  foreground: Colors.white,
                  onTap: () => _act(NotificationActionIds.taken),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _BigButton(
                        label: '稍后$snoozeMinutes分钟',
                        icon: Icons.alarm_rounded,
                        background: const Color(0xFF2A3546),
                        foreground: Colors.white,
                        onTap: () => _act(NotificationActionIds.snooze),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _BigButton(
                        label: '跳过本次',
                        icon: Icons.close_rounded,
                        background: const Color(0xFF2A3546),
                        foreground: const Color(0xFFFFB4A0),
                        onTap: () => _act(NotificationActionIds.skip),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  '处理之前会一直响铃提醒',
                  style: TextStyle(fontSize: AppText.tiny, color: Colors.white38),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
    );
  }
}

/// 响铃页大按钮：高度固定 64，圆角胶囊，字大 —— 戴老花镜也能看清
class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 26, color: foreground),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
