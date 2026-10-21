import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音识别引擎抽象
///
/// 为什么要抽象：V1 用系统 ASR（免费、可离线、无隐私外传），
/// V2 若要上云端 ASR（识别方言/药名更准、支持热词），
/// 只需新增一个实现，页面与解析逻辑完全不用改。
abstract class AsrEngine {
  Future<bool> init();

  bool get isListening;

  /// [onResult] 会多次回调（部分结果 → 最终结果），isFinal 为 true 时表示一句话结束
  Future<void> start({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message)? onError,
    String localeId,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// 系统级 ASR 实现
/// - iOS：Speech framework（设备端可离线识别）
/// - Android：SpeechRecognizer（依赖系统语音服务，MIUI/EMUI 一般自带）
class SystemAsrEngine implements AsrEngine {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> init() async {
    if (_ready) return true;
    _ready = await _speech.initialize(
      onError: (SpeechRecognitionError e) {
        // 老人听不懂错误码，错误文案在 UI 层统一转成大白话
        // ignore: avoid_print
        print('[ASR] error: ${e.errorMsg}');
      },
      onStatus: (String status) {
        // ignore: avoid_print
        print('[ASR] status: $status');
      },
    );
    return _ready;
  }

  @override
  Future<void> start({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message)? onError,
    String localeId = 'zh_CN',
  }) async {
    final ok = await init();
    if (!ok) {
      onError?.call('麦克风或语音识别不可用');
      return;
    }
    await _speech.listen(
      localeId: localeId,
      // 停顿 3 秒自动断句：老人说话慢，别太早截断
      pauseFor: const Duration(seconds: 3),
      listenFor: const Duration(seconds: 30),
      onResult: (result) => onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        autoPunctuation: false,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}
