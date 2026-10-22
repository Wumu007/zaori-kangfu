import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音识别引擎抽象
///
/// 为什么抽象：V1 用系统 ASR（免费、可离线、无隐私外传），
/// 换云端 ASR（识别方言/药名更准、支持热词）时只需新增一个实现，
/// 页面与解析逻辑完全不用改。
abstract class AsrEngine {
  Future<bool> init();

  bool get isListening;

  /// [onResult] 会多次回调：边说边给**部分结果**（isFinal=false），
  /// 一句话停顿后被系统确认为**最终结果**（isFinal=true）。
  /// 长句子可能产生多段 final —— 调用方必须把多段**拼接**起来，
  /// 不能只留最后一段，否则「说完了」时会丢掉前面说过的话。
  Future<void> start({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message)? onError,
    void Function()? onStopped,
    String localeId,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// 系统级 ASR 实现
/// - iOS：Speech framework（设备端可离线识别）
/// - Android：SpeechRecognizer（依赖系统语音服务，MIUI/EMUI 一般自带）
///
/// 【V1.2 问题修复】「点进去只显示正在听，说话没反应，点说完了也不填字」：
/// 1. 之前 `cancelOnError: true`，识别服务一抖动（超时/网络/no_match）就把整个
///    会话悄悄取消，UI 层不知道，一直停在「正在听」—— 现在改为不自动取消，
///    并且把会话结束（status: done / notListening）通过 [onStopped] 报给 UI，
///    让界面同步退出收音态，而不是永久卡住；
/// 2. `ListenMode.dictation`（听写模式）部分国产 ROM 不支持，识别根本不启动 ——
///    改用兼容性最好的 `confirmation`（确认模式），中文识别各家 ROM 都走这条；
/// 3. 部分结果（partialResults）保持开启，UI 才能「边说边出字」。
class SystemAsrEngine implements AsrEngine {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;

  /// 当前这次收音的「会话结束」回调，start() 时设置。
  /// initialize 只能绑一次 onStatus，所以这里做一层转发。
  void Function()? _stoppedCb;

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
        // 监听会话结束：自然停 / 超时 / 系统打断都会走到 done。
        // UI 靠这个退出「正在听」，不再永久卡住。
        if (status == 'done' || status == 'notListening') {
          _stoppedCb?.call();
        }
      },
    );
    return _ready;
  }

  @override
  Future<void> start({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message)? onError,
    void Function()? onStopped,
    String localeId = 'zh_CN',
  }) async {
    final ok = await init();
    if (!ok) {
      onError?.call('麦克风或语音识别不可用');
      onStopped?.call();
      return;
    }
    _stoppedCb = onStopped;
    await _speech.listen(
      localeId: localeId,
      // 停顿 3 秒自动断句：老人说话慢，别太早截断
      pauseFor: const Duration(seconds: 3),
      listenFor: const Duration(seconds: 45),
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        // 关键：出错不自动取消会话，错误交给上层提示，用户还能点「说完了」
        cancelOnError: false,
        // confirmation 模式在国产 ROM 上兼容性最好；dictation 多家不支持
        listenMode: ListenMode.confirmation,
        autoPunctuation: false,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}
