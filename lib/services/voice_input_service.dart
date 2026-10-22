import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medication_draft.dart';
import 'asr_engine.dart';
import 'medication_nlu.dart';

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

  /// 开始收音
  ///
  /// 返回 false 表示没能进入收音状态（多半是麦克风被拒或没有语音服务），
  /// 此时 [onError] 已经带着人话说明被调用过了。
  ///
  /// [onFinal] 会因**多段断句**被调用多次（说一大段话会分成好几段 final），
  /// 调用方负责把多段拼接成完整文本。
  /// [onStopped] 在识别会话结束时回调（自然结束/超时/系统打断），
  /// UI 靠它退出收音态 —— V1.2「一直显示正在听」就是因为缺这个回调。
  ///
  /// V1.4.0：新增 [onFailure]，把「哪一类失败」也传出去。
  /// 之前所有失败都变成同一句「没听清，再说一次」，但**没有语音服务时
  /// 重试一万次也不会成功** —— 用户（老人）只会反复对手机喊，
  /// 得不到任何可执行的引导。现在 UI 能按类型给「去装语音服务」
  /// 还是「重说一次」的不同动作。
  Future<bool> start({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
    void Function(MicGate gate)? onMicBlocked,
    void Function()? onStopped,
    void Function(AsrFailure kind, String readableError)? onFailure,
  }) async {
    final MicGate mic = await ensureMic();
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
    if (!ready) {
      const String msg = '这台手机没有可用的语音识别。\n'
          '可以用下面的键盘输入，不影响使用。';
      onError(msg);
      onFailure?.call(AsrFailure.noEngine, msg);
      onStopped?.call();
      return false;
    }

    await _engine.start(
      onResult: (text, isFinal) {
        if (text.trim().isEmpty) return;
        if (isFinal) {
          onFinal(text.trim());
        } else {
          onPartial(text.trim());
        }
      },
      onError: (message, kind) {
        final String human = _humanizeError(message, kind);
        onError(human);
        onFailure?.call(kind, human);
      },
      onStopped: onStopped,
    );
    return true;
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
  /// V1.4.0：加入 [AsrFailure] 分类。关键区别在于：
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
