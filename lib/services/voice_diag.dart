import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:io';

/// 语音链路诊断日志
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.5.0 为什么必须有它
/// ═══════════════════════════════════════════════════════════════════
///
/// V1.4.0 按插件源码逐行修完了 4 个确定缺陷（doneNoResult、错误透传、
/// 看门狗、localeId），编译通过、单测全绿 —— 但真机上**仍然说不出话**。
/// 而我们手里只有一句「无法使用」，没有任何运行时证据，再修就是盲猜。
///
/// 这份日志把语音链路的每一步都记下来（带时间戳）：
///   权限 → initialize → locales → listen → 部分结果 → 最终结果 →
///   错误码 → 看门狗 → 系统语音对话框 → 对话框返回值。
///
/// 用户在语音录入页「复制诊断信息」发回来，就能确定卡在哪一步：
/// - 卡在 init=false 且 locales 为空 → 这台手机没有语音服务；
/// - 卡在 listen 后既无结果也无 done → 插件与厂商服务连接失败；
/// - 系统对话框正常返回文字 → 插件路径在这个 ROM 上废了，走对话框。
class VoiceDiag {
  VoiceDiag._();
  static final VoiceDiag instance = VoiceDiag._();

  static const int _maxEntries = 200;

  final List<String> _lines = <String>[];
  final Stopwatch _clock = Stopwatch()..start();

  /// 新增一条。永远不抛异常 —— 日志绝不能把主链路带崩。
  void log(String event, [String detail = '']) {
    try {
      final String ts =
          Duration(milliseconds: _clock.elapsedMilliseconds).toString();
      final String line = detail.isEmpty ? '[$ts] $event' : '[$ts] $event | $detail';
      _lines.add(line);
      if (_lines.length > _maxEntries) _lines.removeRange(0, 16);
      if (kDebugMode) debugPrint('VOICE-DIAG $line');
      // 异步落盘，失败静默
      unawaited(_persist());
    } catch (_) {}
  }

  /// 最近一次「手机语音」事件的汇总文本（给用户复制发回来）
  String report() {
    final StringBuffer sb = StringBuffer()
      ..writeln('== 语音诊断（早日康复）==')
      ..writeln('生成时间: ${DateTime.now().toIso8601String()}');
    if (_lines.isEmpty) {
      sb.writeln('（还没有记录 —— 请先点一次语音按钮再回来复制）');
    } else {
      for (final String l in _lines) {
        sb.writeln(l);
      }
    }
    return sb.toString();
  }

  Future<void> _persist() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/voice_diag.txt');
      await f.writeAsString(report(), flush: false);
    } catch (_) {
      // 磁盘满/权限等：忽略，内存里那份仍在
    }
  }
}
