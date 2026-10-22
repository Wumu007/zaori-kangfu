import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 响铃页与通知动作处理之间的事件总线
///
/// ═══════════════════════════════════════════════════════════════════
/// 为什么需要它
/// ═══════════════════════════════════════════════════════════════════
///
/// 响铃页（[RingPage] 路由）弹出的同时，**通知栏上的三个按钮也还在**：
/// 用户可以不进响铃页、直接在通知栏点「已服药」。那一刻：
///
/// - Dart 侧收到 action 回调，写库、取消通知（main.dart 里处理）；
/// - 响铃页可能还开着（比如用户从通知点进来后，又从通知栏点了按钮），
///   必须有人告诉它「这条已经被处理了，该停铃退出了」。
///
/// 处理完一条后 [handle] 广播这条的 payload；响铃页监听 [handled]，
/// 发现 med+at 与自己一致就停止响铃并自动退出。
class AlarmBus {
  AlarmBus._();
  static final AlarmBus instance = AlarmBus._();

  /// 最近一次被处理掉的提醒（payload 解析后的原始字段）
  final ValueNotifier<Map<String, String?>?> handled = ValueNotifier(null);

  /// 通知按钮 / 响铃页按钮处理完成后调用
  void handle(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      handled.value = <String, String?>{
        'med': data['med'] as String?,
        'at': data['at'] as String?,
      };
    } catch (_) {}
  }

  /// 这条 payload 是否已被处理过（响铃页用它判断要不要自动关闭）
  bool isHandled(String payload) {
    final Map<String, String?>? last = handled.value;
    if (last == null) return false;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      return data['med'] == last['med'] && data['at'] == last['at'];
    } catch (_) {
      return false;
    }
  }
}
