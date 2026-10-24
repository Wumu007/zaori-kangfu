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
/// V1.7.0：改为**跨启动累积**（用户 V1.6.0 实测反馈第 1 条）
/// ═══════════════════════════════════════════════════════════════════
///
/// 上一版每次冷启动都从空列表开始、落盘时整份覆盖 —— 等于
/// 「每次进 App 日志就被清空」。而真实问题往往发生在**上一次运行**
/// （到点没响、点通知黑屏），等用户回到 App 想导出时证据已经没了。
///
/// 现在：
/// - [bootstrap] 启动时把已有文件读回内存（只留最近 [maxLines] 行）；
/// - 之后所有记录都追加，落盘写「历史 + 本次」；
/// - 超过 [maxLines] 自动丢最旧的，避免无限膨胀；
/// - 报告头标明「本次会话 X 条 / 累计 Y 条」，能看出跨了几次启动。
///
/// 日志只存本机应用私有目录，不联网、不上传。
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  /// 累计保留的最大行数
  static const int maxLines = 1500;
  static const String _fileName = 'app_log.txt';

  /// 历史 + 本次，统一存在这里（导出时按顺序输出）
  final List<String> _all = <String>[];
  int _sessionCount = 0;

  final Stopwatch _clock = Stopwatch()..start();
  Timer? _flushTimer;
  String _sessionId = '';
  bool _booted = false;

  String get sessionId {
    if (_sessionId.isEmpty) {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    }
    return _sessionId;
  }

  /// 本次会话写入了多少条
  int get sessionCount => _sessionCount;

  /// 最近 N 条（设置页展示用，含历史）
  List<String> recent([int n = 80]) {
    if (_all.length <= n) return List<String>.from(_all);
    return _all.sublist(_all.length - n);
  }

  /// 累计条数
  int get length => _all.length;

  /// 启动时调用一次：把上次运行留下的日志读回内存
  ///
  /// 读失败（首次安装、文件损坏）不影响使用，静默从空开始。
  Future<void> bootstrap() async {
    if (_booted) return;
    _booted = true;
    _sessionId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    try {
      final File f = await _file();
      if (await f.exists()) {
        final String content = await f.readAsString();
        final List<String> parsed = content
            .split('\n')
            .where((String l) => l.startsWith('['))
            .toList();
        if (parsed.length > maxLines) {
          parsed.removeRange(0, parsed.length - maxLines);
        }
        _all.addAll(parsed);
      }
    } catch (_) {}
    // 分隔线：明确「以下是本次启动」
    _append('${_stamp()}[APP] ───── 本次启动 session=$_sessionId ─────');
  }

  /// 写一条日志。永远不抛异常 —— 日志绝不能把主链路带崩。
  void log(String tag, String event, [String detail = '']) {
    try {
      final String line = detail.isEmpty
          ? '${_stamp()}[$tag] $event'
          : '${_stamp()}[$tag] $event | $detail';
      _append(line);
      if (kDebugMode) debugPrint('APP-LOG $line');
    } catch (_) {}
  }

  /// 记异常（带类型，堆栈只取前 3 行，足够定位）
  void error(String where, Object e, [StackTrace? st]) {
    final String stack =
        (st ?? StackTrace.empty).toString().split('\n').take(3).join(' <- ');
    log(LogTag.error, where,
        '${e.runtimeType}: $e${stack.isEmpty ? '' : ' @ $stack'}');
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

  void _append(String line) {
    _all.add(line);
    _sessionCount++;
    if (_all.length > maxLines) {
      _all.removeRange(0, _all.length - maxLines);
    }
    _scheduleFlush();
  }

  String _stamp() {
    final DateTime d = DateTime.now();
    final Duration elapsed = _clock.elapsed;
    String two(int v) => v.toString().padLeft(2, '0');
    // V1.10.0：毫秒必须和「时分秒」取同一个时钟。
    // 之前取的是 Stopwatch 的毫秒，与 DateTime 的秒不对应，
    // 日志里会出现「同一秒内后写的行毫秒更小」的乱序（例如
    // 22:47:07.701 后面跟着 22:47:07.113），排查时非常误导。
    final String ms = d.millisecond.toString().padLeft(3, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:'
        '${two(d.second)}.$ms +${elapsed.inSeconds}s ';
  }

  /// 完整报告（复制/导出用）
  String report() {
    final StringBuffer sb = StringBuffer()
      ..writeln('===== 早日康复 · 运行日志 =====')
      ..writeln('本次会话: $sessionId（$_sessionCount 条）')
      ..writeln('累计条数: ${_all.length}')
      ..writeln('设备时间: ${DateTime.now().toIso8601String()}')
      ..writeln(
          '平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('-----------------------------------------------');
    if (_all.isEmpty) {
      sb.writeln('（暂无记录：请先使用一次相关功能再导出）');
    } else {
      for (final String l in _all) {
        sb.writeln(l);
      }
    }
    return sb.toString();
  }

  /// 写到缓存目录，返回文件（供系统分享面板导出）
  Future<File?> exportFile() async {
    try {
      final Directory dir = await getTemporaryDirectory();
      final File f = File('${dir.path}/$_fileName');
      await f.writeAsString(report(), flush: true);
      return f;
    } catch (e) {
      log(LogTag.error, '导出日志失败', '$e');
      return null;
    }
  }

  /// 清空（仅用户手动操作）
  Future<void> clear() async {
    _all.clear();
    _sessionCount = 0;
    try {
      final File f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<File> _file() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
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
      final File f = await _file();
      await f.writeAsString(report(), flush: false);
    } catch (_) {
      // 磁盘问题忽略，内存里那份仍在
    }
  }
}
