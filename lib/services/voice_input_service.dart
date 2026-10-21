import 'package:flutter_tts/flutter_tts.dart';

import '../models/medication_draft.dart';
import 'asr_engine.dart';
import 'medication_nlu.dart';

/// 语音录入的编排层：**听 → 解析 → 回读**
///
/// 页面只管 UI 状态，所有「听不清怎么办、听清了怎么解释」都收在这里。
class VoiceInputService {
  VoiceInputService({AsrEngine? engine, FlutterTts? tts})
      : _engine = engine ?? SystemAsrEngine(),
        _tts = tts ?? FlutterTts();

  final AsrEngine _engine;
  final FlutterTts _tts;

  bool _ttsReady = false;

  bool get isListening => _engine.isListening;

  Future<bool> ensureReady() async {
    final asrOk = await _engine.init();
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
  Future<void> start({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
  }) async {
    await ensureReady();
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
