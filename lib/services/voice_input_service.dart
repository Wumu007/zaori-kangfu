import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medication_draft.dart';
import 'app_log.dart';
import 'asr_engine.dart';
import 'medication_nlu.dart';
import 'native_bridge.dart';

// 页面只依赖编排层，不该再单独 import 引擎实现；
// 把失败类型枚举透出去，页面才写得出 `kind == AsrFailure.noEngine`
export 'asr_engine.dart' show AsrFailure;

/// 语音录入的结果：申请麦克风这一步是否成功
///
/// 单独一个枚举而不是 bool，因为「被拒」和「永久拒绝」要给不同的引导：
/// 前者再点一次还会弹系统框，后者只能去系统设置里手动开。
enum MicGate { ok, denied, permanentlyDenied }

/// 收音走的三条路径（日志里用来定位「到底哪条通了」）
class VoicePath {
  VoicePath._();
  static const String native = 'B-原生识别器';
  static const String plugin = 'A-插件';
  static const String dialog = 'C-系统对话框';
}

/// 语音录入的编排层：**听 → 解析 → 回读**
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.6.0：三重路径（第四个版本，不再赌单一路径）
/// ═══════════════════════════════════════════════════════════════════
///
/// 历史：V1.3 插件静默监听 → 不通；V1.4 按插件源码修完 4 个确定缺陷
/// → 仍不通；V1.5 加系统对话框兜底 → 用户反馈仍不可用。
///
/// 三轮下来可以确定：**speech_to_text 插件在这台 iQOO 上的服务连接
/// 就是不通**，而系统对话框需要用户手动点开、部分 ROM 上也失败。
///
/// 所以这一版按「成功率从高到低」串三条路，任一条拿到文字就结束：
///
/// 1. **B · 原生识别器**（优先）
///    直接在 MainActivity 里调 `SpeechRecognizer.createSpeechRecognizer`
///    + 自己的 RecognitionListener，绕开插件全部封装。这条路的代码
///    完全在我们手里，出问题日志能指到具体某一行。
///
/// 2. **A · 插件** —— 原生也失败时再试插件（换一种实现碰运气）。
///
/// 3. **C · 系统对话框** —— 最后兜底：弹微信同款系统语音窗口。
///
/// 三条都失败才判定不可用，全程写进 [AppLog]，
/// 用户可从「我的 → 运行日志」导出。
class VoiceInputService {
  VoiceInputService({AsrEngine? engine, FlutterTts? tts})
      : _engine = engine ?? SystemAsrEngine(),
        _tts = tts ?? FlutterTts();

  final AsrEngine _engine;
  final FlutterTts _tts;

  bool _ttsReady = false;

  /// 进程内缓存：本次运行已经确认过麦克风可用
  static bool _micConfirmed = false;

  bool get isListening => _engine.isListening;

  /// 首次使用时申请一次麦克风权限
  ///
  /// 只调一次 `Permission.microphone.request()`：系统已授权时它会立即返回
  /// granted（不弹框），没授权才弹系统框。
  Future<MicGate> ensureMic() async {
    if (_micConfirmed) return MicGate.ok;
    final PermissionStatus status = await Permission.microphone.status;
    if (status.isGranted || status.isLimited) {
      _micConfirmed = true;
      return MicGate.ok;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return MicGate.permanentlyDenied;
    }
    final PermissionStatus asked = await Permission.microphone.request();
    if (asked.isGranted || asked.isLimited) {
      _micConfirmed = true;
      return MicGate.ok;
    }
    return asked.isPermanentlyDenied
        ? MicGate.permanentlyDenied
        : MicGate.denied;
  }

  Future<bool> ensureReady() async {
    final MicGate mic = await ensureMic();
    if (mic != MicGate.ok) return false;
    final bool asrOk = await _engine.init();
    if (!_ttsReady) {
      // TTS 只用于「回读确认」，部分精简 ROM 没有系统 TTS 引擎会直接抛异常。
      // 这里不能让它把语音识别一起带崩：识别成功才是主链路。
      try {
        // 老人听得清：稍慢一点的语速说普通话
        await _tts.setLanguage('zh-CN');
        await _tts.setSpeechRate(0.45);
        await _tts.setVolume(1.0);
        _ttsReady = true;
      } catch (_) {
        _ttsReady = false;
      }
    }
    return asrOk;
  }

  /// 开始收音：B → A → C 依次尝试，拿到文字即停
  ///
  /// 返回 false 表示三条路都没拿到文字，此时 [onError] 已带人话说明。
  /// [onFinal] 会因多段断句被调用多次，调用方负责拼接。
  /// [onStopped] 在整个流程结束时回调（UI 靠它退出收音态）。
  Future<bool> start({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
    void Function(MicGate gate)? onMicBlocked,
    void Function()? onStopped,
    void Function(AsrFailure kind, String readableError)? onFailure,
  }) async {
    final AppLog logx = AppLog.instance;
    logx.voice('══ 语音会话开始 ══', 'app=${logx.sessionId}');

    final MicGate mic = await ensureMic();
    logx.voice('麦克风权限', '$mic');
    if (mic != MicGate.ok) {
      onMicBlocked?.call(mic);
      final String msg = mic == MicGate.permanentlyDenied
          ? '麦克风被关掉了，点这里去设置里打开'
          : '需要麦克风才能说话，点一下允许就行';
      onError(msg);
      onFailure?.call(AsrFailure.noPermission, msg);
      onStopped?.call();
      return false;
    }

    // ---- 路径 B：原生识别器（优先，代码可控）----
    final String? b = await _tryNativePath(onPartial: onPartial, onFinal: onFinal);
    if (b != null && b.trim().isNotEmpty) {
      logx.voice('成功路径', VoicePath.native);
      onStopped?.call();
      return true;
    }

    // ---- 路径 A：插件 ----
    final String? a = await _tryPluginPath(onPartial: onPartial, onFinal: onFinal);
    if (a != null && a.trim().isNotEmpty) {
      logx.voice('成功路径', VoicePath.plugin);
      onStopped?.call();
      return true;
    }

    // ---- 路径 C：系统对话框（用户看得见，最后兜底）----
    final String? c = await _tryDialogPath(onFinal: onFinal);
    if (c != null && c.trim().isNotEmpty) {
      logx.voice('成功路径', VoicePath.dialog);
      onStopped?.call();
      return true;
    }

    // ---- 三条都失败 ----
    final List<String> services = await NativeBridge.speechServices();
    logx.voice('全部路径失败', '系统语音服务=[${services.join(',')}]');
    final String msg = services.isEmpty
        ? '这台手机没有可用的语音识别服务。\n用下面的键盘输入一样快。'
        : '语音没有收到内容。\n可以再说一次，或用下面的键盘输入。';
    onError(msg);
    onFailure?.call(AsrFailure.noEngine, msg);
    onStopped?.call();
    return false;
  }

  // ------------------------------------------------------------ 路径 B

  /// 原生识别器：MainActivity 的 SpeechRecognizer，事件经 MethodChannel 回传
  ///
  /// 超时 7 秒：给出足够时间说一句话，又不至于让用户干等太久。
  /// 三条路径是串联的，每条超时都会累加到用户等待时间里。
  Future<String?> _tryNativePath({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
  }) async {
    final AppLog logx = AppLog.instance;
    if (!Platform.isAndroid) {
      logx.voice('路径B 跳过', '非 Android');
      return null;
    }
    if (!await NativeBridge.nativeAsrAvailable) {
      logx.voice('路径B 不可用', '系统无识别服务');
      return null;
    }

    final Completer<String?> done = Completer<String?>();
    String buf = '';
    StreamSubscription<NativeAsrEvent>? sub;
    Timer? timeout;

    void finish(String? v) {
      if (!done.isCompleted) done.complete(v);
    }

    NativeBridge.bindAsrHandler();
    sub = NativeBridge.asrEvents.listen((NativeAsrEvent e) {
      if (e.isResult || e.isError || e.isEnd || e.text.isNotEmpty) {
        logx.voice('路径B 事件', '${e.type} "${e.text}" code=${e.code}');
      }
      if (e.isPartial) onPartial(e.text);
      if (e.isResult) {
        buf = e.text;
        if (e.text.trim().isNotEmpty) onFinal(e.text.trim());
        finish(buf);
      } else if (e.isError) {
        // 错误码：6=SPEECH_TIMEOUT 7=NO_MATCH 1/2=网络
        // 9=权限不足 10/11=服务不可用。有部分文字也算成功。
        finish(buf.trim().isEmpty ? null : buf);
      }
    });

    final bool started = await NativeBridge.startNativeAsr();
    if (!started) {
      logx.voice('路径B 启动失败');
      await sub.cancel();
      return null;
    }
    logx.voice('路径B 已开始收音');

    timeout = Timer(const Duration(seconds: 7), () {
      logx.voice('路径B 超时', '7 秒');
      finish(buf.trim().isEmpty ? null : buf);
    });

    final String? r = await done.future;
    timeout.cancel();
    await sub.cancel();
    await NativeBridge.stopNativeAsr();
    return r;
  }

  // ------------------------------------------------------------ 路径 A

  /// 插件路径：speech_to_text（先 init，再 listen）
  Future<String?> _tryPluginPath({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
  }) async {
    final AppLog logx = AppLog.instance;

    bool ready = false;
    try {
      ready = await _engine
          .init()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (e, st) {
      logx.error('路径A init', e, st);
    }
    logx.voice('路径A 插件初始化', ready ? '成功' : '失败或超时');
    if (!ready) return null;

    final Completer<String?> done = Completer<String?>();
    String buf = '';
    Timer? timeout;

    await _engine.start(
      onResult: (String text, bool isFinal) {
        if (text.trim().isEmpty) return;
        logx.voice(isFinal ? '路径A 最终结果' : '路径A 部分结果', text);
        if (isFinal) {
          buf += text;
          onFinal(text.trim());
        } else {
          onPartial(text.trim());
        }
      },
      onError: (String message, AsrFailure kind) {
        logx.voice('路径A 错误', '$kind | $message');
      },
      onStopped: () {
        logx.voice('路径A 会话结束', '累计 ${buf.trim().length} 字');
        if (!done.isCompleted) {
          done.complete(buf.trim().isEmpty ? null : buf);
        }
      },
    );
    logx.voice('路径A listen 已下发');

    timeout = Timer(const Duration(seconds: 4), () {
      logx.voice('路径A 超时', '4 秒');
      if (!done.isCompleted) {
        done.complete(buf.trim().isEmpty ? null : buf);
      }
    });

    final String? r = await done.future;
    timeout.cancel();
    await _engine.cancel();
    return r;
  }

  // ------------------------------------------------------------ 路径 C

  /// 系统对话框：微信同款，用户看得见地说一句
  Future<String?> _tryDialogPath({
    required void Function(String finalText) onFinal,
  }) async {
    final AppLog logx = AppLog.instance;
    logx.voice('路径C 打开系统语音对话框');
    final String? text = await NativeBridge.showSystemSpeechDialog();
    logx.voice('路径C 返回', text == null ? '无文字' : '${text.length} 字');
    if (text != null && text.trim().isNotEmpty) {
      onFinal(text.trim());
      return text;
    }
    return null;
  }

  // ------------------------------------------------------------ 其它

  Future<void> stop() => _engine.stop();

  Future<void> cancel() async {
    await NativeBridge.stopNativeAsr();
    await _engine.cancel();
  }

  /// 解析（纯函数，测试友好）
  MedicationDraft parse(String text) => MedicationNlu.parse(text);

  /// 回读确认：把「我听到的是…」念给用户听
  Future<void> speakBack(MedicationDraft draft) async {
    await ensureReady();
    // 念不出来不算错误：用户已经看到识别结果了，静默跳过即可
    try {
      await _tts.stop();
      await _tts.speak(draft.readBackText);
    } catch (_) {}
  }

  /// 只说一句短语
  Future<void> speak(String text) async {
    await ensureReady();
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await NativeBridge.stopNativeAsr();
    await _engine.cancel();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// 系统错误码 → 老人能听懂的一句话
  static String humanizeError(String raw, [AsrFailure? kind]) =>
      _humanizeError(raw, kind);

  static String _humanizeError(String raw, [AsrFailure? kind]) {
    final k = kind ?? _guessKind(raw);
    switch (k) {
      case AsrFailure.noEngine:
        return '这台手机没有安装可用的语音识别服务。\n'
            '可以改用下面的键盘输入；装一个「语音服务」后再回来试。';
      case AsrFailure.noPermission:
        return '没有麦克风权限，请到手机设置里把「录音」允许给它。';
      case AsrFailure.heardNothing:
        return '没有听到声音。靠近一点、说大声一点再试一次，或者用键盘输入。';
      case AsrFailure.other:
        break;
    }
    final s = raw.toLowerCase();
    if (s.contains('network')) return '网络不太好，稍等一下再试';
    if (s.contains('busy')) return '正在录音，请稍等';
    return '没听清，再说一次好吗？';
  }

  static AsrFailure _guessKind(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('no_engine') ||
        s.contains('no_chinese') ||
        s.contains('recognizer') ||
        s.contains('language')) {
      return AsrFailure.noEngine;
    }
    if (s.contains('permission')) return AsrFailure.noPermission;
    if (s.contains('no_match') ||
        s.contains('timeout') ||
        s.contains('watchdog') ||
        s.contains('done_no_result')) {
      return AsrFailure.heardNothing;
    }
    return AsrFailure.other;
  }
}
