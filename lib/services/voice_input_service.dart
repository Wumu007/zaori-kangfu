import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medication_draft.dart';
import 'asr_engine.dart';
import 'medication_nlu.dart';

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
      // 老人听得清：稍慢一点的语速说普通话
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
      _ttsReady = true;
    }
    return asrOk;
  }

  /// 开始收音
  ///
  /// 返回 false 表示没能进入收音状态（多半是麦克风被拒），
  /// 此时 [onError] 已经带着人话说明被调用过了。
  Future<bool> start({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
    void Function(MicGate gate)? onMicBlocked,
  }) async {
    final MicGate mic = await ensureMic();
    if (mic != MicGate.ok) {
      onMicBlocked?.call(mic);
      onError(mic == MicGate.permanentlyDenied
          ? '麦克风被关掉了，点这里去设置里打开'
          : '需要麦克风才能说话，点一下允许就行');
      return false;
    }

    final bool ready = await ensureReady();
    if (!ready) {
      onError('这台手机的语音识别用不了，可以改用键盘输入');
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
      onError: (message) => onError(_humanizeError(message)),
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
    await _tts.stop();
    await _tts.speak(draft.readBackText);
  }

  /// 只说一句短语
  Future<void> speak(String text) async {
    await ensureReady();
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> dispose() async {
    await _engine.cancel();
    await _tts.stop();
  }

  /// 系统错误码 → 老人能听懂的一句话
  static String _humanizeError(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('permission') || s.contains('denied')) {
      return '没有麦克风权限，请在手机设置里允许录音';
    }
    if (s.contains('no_match') || s.contains('nomatch')) {
      return '没听清，再说一次好吗？';
    }
    if (s.contains('network')) {
      return '网络不太好，稍等一下再试';
    }
    if (s.contains('busy')) {
      return '正在录音，请稍等';
    }
    return '没听清，再说一次好吗？';
  }
}
