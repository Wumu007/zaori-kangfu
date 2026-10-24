import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 分类标签：日志按来源打标签，导出后一眼能看出问题出在哪条链路
class LogTag {
  LogTag._();
  static const String app = 'APP'; // 启动、生命周期
  static const String voice = 'VOICE'; // 语音识别全链路
  static const String notify = 'NOTIFY'; // 排程 / 通知 / 响铃
  static const String perm = 'PERM'; // 权限状态快照
  static const String error = 'ERROR'; // 异常堆栈
}

/// 应用运行日志
///
/// ═══════════════════════════════════════════════════════════════════
/// 为什么必须有（用户 V1.5.0 反馈第 3 条直接要求）
/// ═══════════════════════════════════════════════════════════════════
///
/// 语音连续三个版本修不好、后台提醒连续两版不准 —— 根本原因不是不会改，
/// 而是**手里没有运行时证据**：只知道「不行」，不知道死在哪一步。
///
/// 这份日志按链路打标签：
/// - [LogTag.voice]：麦克风权限 → 插件初始化 → 支持的语言 → listen →
///   结果/错误码 → 看门狗 → 原生识别器 → 系统对话框，每一步都有时间戳；
/// - [LogTag.notify]：每次排程的 id/时刻/成功失败、排程总数、电池白名单
///   状态、前台服务状态、通知是否真的发出；
/// - [LogTag.perm]：启动时完整权限快照（通知/精确闹钟/电池/麦克风）；
/// - [LogTag.error]：所有捕获到的异常。
///
/// 用户从「我的 → 运行日志」一键复制或导出文件发回来，就能精确定位。
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _maxEntries = 400;
  static const String _fileName = 'app_log.txt';

  final List<String> _lines = <String>[];
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _flushTimer;
  String _sessionId = '';

  /// 会话 id：每次冷启动换一个，日志里能区分「这是哪一次运行」
  String get sessionId => _sessionId;

  /// 最近 N 条（设置页展示用）
  List<String> recent([int n = 80]) {
    if (_lines.length <= n) return List<String>.from(_lines);
    return _lines.sublist(_lines.length - n);
  }

  int get length => _lines.length;

  /// 写一条日志。永远不抛异常 —— 日志绝不能把主链路带崩。
  void log(String tag, String event, [String detail = '']) {    try {
      if (_sessionId.isEmpty) {
        _sessionId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      }
      final String ts = _stamp();
      final String line = detail.isEmpty
          ? '[$ts][$tag] $event'
          : '[$ts][$tag] $event | $detail';
      _lines.add(line);
      if (_lines.length > _maxEntries) _lines.removeRange(0, 32);
      if (kDebugMode) debugPrint('APP-LOG $line');
      _scheduleFlush();
    } catch (_) {}
  }

  /// 记异常（带类型，不带超长堆栈 —— 只取前 3 行足够定位）
  void error(String where, Object e, [StackTrace? st]) {
    final String stack = (st ?? StackTrace.empty)
        .toString()
        .split('\n')
        .take(3)
        .join(' <- ');
    log(LogTag.error, where, '${e.runtimeType}: $e${stack.isEmpty ? '' : ' @ $stack'}');
  }

  /// 语音链路简写
  void voice(String event, [String detail = '']) =>
      log(LogTag.voice, event, detail);

  /// 提醒/通知链路简写
  void notify(String event, [String detail = '']) =>
      log(LogTag.notify, event, detail);

  /// 权限快照简写
  void perm(String event, [String detail = '']) =>
      log(LogTag.perm, event, detail);

  String _stamp() {
    final d = DateTime.now();
    final elapsed = _clock.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    final String ms = elapsed.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}'
        '.$ms +${elapsed.inSeconds}s';
  }

  /// 完整报告（复制/导出用）
  String report() {
    final StringBuffer sb = StringBuffer()
      ..writeln('===== 早日康复 · 运行日志 =====')
      ..writeln('会话: ${sessionId.isEmpty ? '-' : sessionId}')
      ..writeln('设备时间: ${DateTime.now().toIso8601String()}')
      ..writeln('平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('日志条数: ${_lines.length}')
      ..writeln('-----------------------------------------------');
    for (final String l in _lines) {
      sb.writeln(l);
    }
    if (_lines.isEmpty) sb.writeln('（暂无记录：请先使用一次相关功能再导出）');
    return sb.toString();
  }

  /// 写到缓存目录，返回文件（供系统分享面板导出）
  Future<File?> exportFile() async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$_fileName');
      await f.writeAsString(report(), flush: true);
      return f;
    } catch (e) {
      log(LogTag.error, '导出日志失败', '$e');
      return null;
    }
  }

  Future<void> clear() async {
    _lines.clear();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 落盘做 300ms 防抖：语音识别过程中会密集写日志，避免频繁 IO
  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_fileName');
      await f.writeAsString(report(), flush: false);
    } catch (_) {
      // 磁盘问题忽略，内存里那份仍在
    }
  }
}
