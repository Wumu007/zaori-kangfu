import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medication_draft.dart';
import 'asr_engine.dart';
import 'medication_nlu.dart';
import 'native_bridge.dart';
import 'voice_diag.dart';

// 页面只依赖编排层，不该再单独 import 引擎实现；
// 把失败类型枚举透出去，页面才写得出 `kind == AsrFailure.noEngine`
export 'asr_engine.dart' show AsrFailure;

/// 语音录入的结果：申请麦克风这一步是否成功
///
/// 单独一个枚举而不是 bool，因为「被拒」和「永久拒绝」要给不同的引导：
/// 前者再点一次还会弹系统框，后者只能去系统设置里手动开。
enum MicGate { ok, denied, permanentlyDenied }

/// 语音录入的编排层：**听 → 解析 → 回读**
///
/// 页面只管 UI 状态，所有「听不清怎么办、听清了怎么解释」都收在这里。
///
/// 麦克风权限的时机（用户明确要求的）：
/// **不在安装时、也不在启动时申请，而是在第一次真正要用语音录入时申请一次**，
/// 之后跨会话记住结果，不再每次都弹。这样不用语音的用户全程不会被问。
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.5.0：双路径收音
/// ═══════════════════════════════════════════════════════════════════
///
/// V1.3（插件的静默监听路径）和 V1.4（按插件源码修完 4 个确定缺陷后）
/// 在 iQOO Neo 11 上都「说话没反应」。没有设备日志时无法确认插件路径
/// 到底死在哪一步，所以 V1.5.0 做两件事：
///
/// 1. **每一步都记诊断日志**（[VoiceDiag]），用户可一键复制发回来，
///    下次再反馈时我们能精确知道卡在哪一步；
///
/// 2. **插件路径拿不到文字时，自动切系统「语音输入」对话框**
///    （`RecognizerIntent.ACTION_RECOGNIZE_SPEECH`，经 [NativeBridge]）。
///    这条路由「当前默认语音引擎」弹出标准麦克风对话框，说完把文字
///    返回 —— 微信语音转文字用的就是它，不依赖插件自己去连服务，
///    在 vivo/iQOO 这类定制 ROM 上兼容性远好于插件的静默监听。
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

  /// 开始收音（插件路径 → 失败自动切系统对话框）
  ///
  /// 返回 false 表示两条路径都没拿到文字（或没能开始），
  /// 此时 [onError] 已带人话说明。
  ///
  /// [onFinal] 会因**多段断句**被调用多次，调用方负责拼接多段文本。
  /// [onStopped] 在整个收音流程（含兜底对话框）结束时回调，
  /// UI 靠它退出收音态。
  ///
  /// [onFailure] 把「哪一类失败」传出去：[AsrFailure.noEngine] /
  /// [AsrFailure.noPermission] 重试无意义，必须引导换路径或开权限。
  Future<bool> start({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
    void Function(MicGate gate)? onMicBlocked,
    void Function()? onStopped,
    void Function(AsrFailure kind, String readableError)? onFailure,
  }) async {
    final VoiceDiag diag = VoiceDiag.instance;
    diag.log('──── 新的语音会话 ────');

    final MicGate mic = await ensureMic();
    diag.log('麦克风权限', '$mic');
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

    final bool ready = await ensureReady();
    diag.log('插件引擎初始化', ready ? '成功' : '失败');

    if (!ready) {
      // 插件路径直接没戏 —— 多半是没有语音服务或服务连不上。
      // 直接切系统对话框（这一步的成功与否会在日志里留下证据）。
      return _systemDialogFallback(
        onFinal: onFinal,
        onError: onError,
        onStopped: onStopped,
        onFailure: onFailure,
      );
    }

    // ---- 插件路径（体验更好：无弹窗、实时上屏）----
    String finalBuffer = '';
    bool fallbackTried = false;

    await _engine.start(
      onResult: (text, isFinal) {
        if (text.trim().isEmpty) return;
        diag.log(isFinal ? '最终结果' : '部分结果', text);
        if (isFinal) finalBuffer += text;
        if (isFinal) {
          onFinal(text.trim());
        } else {
          onPartial(text.trim());
        }
      },
      onError: (message, kind) {
        diag.log('插件错误', '$kind | $message');
        // 没有引擎/连不上服务：重试插件没有意义，直接切系统对话框
        if (!fallbackTried && kind == AsrFailure.noEngine) {
          fallbackTried = true;
          _systemDialogFallback(
            onFinal: onFinal,
            onError: onError,
            onStopped: onStopped,
            onFailure: onFailure,
          );
          return;
        }
        final String human = _humanizeError(message, kind);
        onError(human);
        onFailure?.call(kind, human);
      },
      onStopped: () {
        diag.log('插件会话结束', '累计最终文字 ${finalBuffer.trim().length} 字');
        // 一段最终文字都没拿到：这个 ROM 上插件路径不可用，切系统对话框。
        // 只兜底一次，避免对话框→失败→再弹的循环。
        if (finalBuffer.trim().isEmpty && !fallbackTried) {
          fallbackTried = true;
          _systemDialogFallback(
            onFinal: onFinal,
            onError: onError,
            onStopped: onStopped,
            onFailure: onFailure,
          );
          return;
        }
        onStopped?.call();
      },
    );
    diag.log('listen 已下发');
    return true;
  }

  /// 系统语音对话框兜底
  ///
  /// 成功：文字经 [onFinal] 交给上层（与插件路径同一入口，解析逻辑复用）。
  /// 失败：给「这台手机的语音功能用不了」的最终结论 + 键盘输入引导。
  Future<bool> _systemDialogFallback({
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
    void Function()? onStopped,
    void Function(AsrFailure kind, String readableError)? onFailure,
  }) async {
    final VoiceDiag diag = VoiceDiag.instance;
    diag.log('兜底路径', '弹系统语音对话框');

    final List<String> services = await NativeBridge.speechServices();
    diag.log('系统语音服务', services.isEmpty ? '（一个都没有）' : services.join(' / '));

    final String? text = await NativeBridge.showSystemSpeechDialog();
    diag.log('对话框返回', text == null ? '无文字（取消或失败）' : '${text.length} 字');

    if (text != null && text.isNotEmpty) {
      onFinal(text);
      onStopped?.call();
      return true;
    }

    final String msg = services.isEmpty
        ? '这台手机没有语音识别功能。\n用下面的键盘输入一样快。'
        : '语音这次没有听到内容。\n靠近一点再试一次，或用下面的键盘输入。';
    onError(msg);
    onFailure?.call(AsrFailure.noEngine, msg);
    onStopped?.call();
    return false;
  }

  Future<void> stop() => _engine.stop();

  Future<void> cancel() => _engine.cancel();

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
    await _engine.cancel();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// 系统错误码 → 老人能听懂的一句话
  ///
  /// 关键区别：
  /// - [AsrFailure.noEngine] / [AsrFailure.noPermission]：**重试没有意义**，
  ///   必须引导去装服务或开权限；
  /// - [AsrFailure.heardNothing]：可以重说，但要说清「没听到」而不是「没听清」。
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
