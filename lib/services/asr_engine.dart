import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音识别失败时，UI 需要知道「属于哪一类问题」，才能给对不同的话。
///
/// V1.4.0 新增：之前所有失败都变成同一句「没听清，再说一次」，
/// 老人反复重试也没用（因为没有语音服务时重试一万次也不会成功）。
/// 现在分成四类，只有 [heardNothing] 才建议重说。
enum AsrFailure {
  /// 这台手机没有可用的语音识别服务（iQOO/vivo 精简版常见）
  noEngine,

  /// 没有麦克风权限
  noPermission,

  /// 语音服务在，但一句都没识别到（环境吵、离太远、语言包缺失）
  heardNothing,

  /// 其他（网络、忙、服务端错误）
  other,
}

/// 语音识别引擎抽象
///
/// 为什么抽象：V1 用系统 ASR（免费、可离线、无隐私外传），
/// 换云端 ASR（识别方言/药名更准、支持热词）时只需新增一个实现，
/// 页面与解析逻辑完全不用改。
abstract class AsrEngine {
  Future<bool> init();

  bool get isListening;

  /// 最近一次初始化是否成功
  bool get isAvailable;

  /// [onResult] 会多次回调：边说边给**部分结果**（isFinal=false），
  /// 一句话停顿后被系统确认为**最终结果**（isFinal=true）。
  /// 长句子可能产生多段 final —— 调用方必须把多段**拼接**起来，
  /// 不能只留最后一段，否则「说完了」时会丢掉前面说过的话。
  Future<void> start({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message, AsrFailure kind)? onError,
    void Function()? onStopped,
    String? localeId,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// 系统级 ASR 实现
/// - iOS：Speech framework（设备端可离线识别）
/// - Android：SpeechRecognizer（依赖系统语音服务）
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.4.0 修复「说话没反应」（iQOO Neo 11 / Android 15 实测）
/// ═══════════════════════════════════════════════════════════════════
///
/// 逐行对齐 speech_to_text **7.5.0** 的 Android 侧源码后，定位到 4 个真实缺陷。
/// 注意：7.5.0 的 Dart 层**没有** `isRecognitionAvailable` /
/// `isOnDeviceRecognitionAvailable` / `installEngineIfNeeded` 这些方法
/// （只在 Kotlin 侧有），可用的是 `isAvailable`(== _initWorked)、
/// `hasPermission`、`locales()`、`systemLocale()`。所以下面全部基于这 4 个 API。
///
/// 【缺陷 1】`doneNoResult` 状态没处理 → 永久卡在「正在听」【主因】
///   插件 `notifyListening()`：收音结束时若 `resultSent == false`
///   （一个字都没识别到），发的是 `doneNoResult` 而**不是** `done`。
///   原代码只判断 `done` / `notListening` → 会话早结束了，UI 一直显示
///   「正在听，请说话」，用户对手机喊半天没反应。**这就是实测现象**。
///   修复：`doneNoResult` 也当会话结束，并给出「没听到声音」的明确提示。
///
/// 【缺陷 2】错误回调只 print，从不透传给 UI
///   插件 `sendError()` 把 errorMsg（如 `error_speech_timeout`、
///   `error_no_match`、`error_network`）发给 Dart 的 onError。
///   原代码在 onError 里只 `print`，然后**什么都没做**：界面既不提示，
///   也不退出收音态。等于用户永远得不到任何反馈。
///   修复：错误透传给上层 + 致命错误强制收尾。
///
/// 【缺陷 3】`listen()` 同步返回，不代表真的开始收音
///   插件 `startListening()`：`handler.post { startListening(...) }` 是异步，
///   但 `result.success(true)` 是同步返回。服务起不来时调用方仍以为在听。
///   修复：加「收音看门狗」——6 秒内既无任何文字也无错误，主动判为
///   [AsrFailure.heardNothing] 收尾，不让老人干等。
///
/// 【缺陷 4】`localeId: 'zh_CN'` 反而让插件不下发语言
///   插件 `setupRecognizerIntent()`：只有
///   `if (languageTag != Locale.getDefault().toLanguageTag())`
///   才 put `EXTRA_LANGUAGE`。系统默认就是 `zh-CN` 时条件为假，
///   语言标签不下发，完全靠语音服务默认模型（某些 ROM 默认不是普通话）。
///   修复：用 `locales()` 查设备真实支持的中文标签再传；
///   查不到说明该机语音服务不支持中文，明确告知而不是静默失败。
class SystemAsrEngine implements AsrEngine {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;

  @override
  bool get isAvailable => _ready;

  /// 当前这次收音的「会话结束」回调，start() 时设置。
  /// initialize 只能绑一次 onStatus，所以这里做一层转发。
  void Function()? _stoppedCb;

  /// 当前这次收音的错误回调（initialize 时注册，start 时替换）
  void Function(String message, AsrFailure kind)? _errorCb;

  /// 本次收音是否已经收到过任何文字（含 partial）
  bool _gotAnyText = false;

  /// 收音看门狗：超时无任何反馈就主动收尾
  Timer? _watchdog;

  /// 会话结束只上报一次：done + notListening 会连着来，避免 UI 抽搐
  bool _stoppedReported = true;

  static const Duration _watchdogTimeout = Duration(seconds: 6);

  @override
  bool get isListening => _speech.isListening;

  @override
  Future<bool> init() async {
    if (_ready) return true;
    // 先确认系统给没给录音权限：没权限时 initialize 必然 false，
    // 但我们要把原因说清（去设置里开）而不是笼统说「不可用」。
    bool hasPerm = false;
    try {
      hasPerm = await _speech.hasPermission;
    } catch (_) {
      hasPerm = false;
    }
    if (!hasPerm) {
      _ready = false;
      return false;
    }

    try {
      _ready = await _speech.initialize(
        onError: (SpeechRecognitionError e) {
          final kind = _classify(e.errorMsg);
          _errorCb?.call(e.errorMsg, kind);
          // 致命错误（无权限/无服务）必须收尾，否则界面停在「正在听」
          if (e.permanent) _reportStopped();
        },
        onStatus: (String status) {
          // 插件可能发：listening / notListening / done / doneNoResult
          if (status == 'done' ||
              status == 'notListening' ||
              status == 'doneNoResult') {
            if (status == 'doneNoResult' && !_gotAnyText) {
              _errorCb?.call('done_no_result', AsrFailure.heardNothing);
            }
            _reportStopped();
          }
        },
        // 线上关掉；排查特定机型时改成 true，日志会进 logcat
        debugLogging: false,
      );
    } catch (_) {
      _ready = false;
      return false;
    }
    return _ready;
  }

  /// 设备是否支持中文识别；返回可用的 localeId，null 表示不支持
  ///
  /// 这一步同时充当「有没有语音服务」的判断：`locales()` 空列表
  /// 或抛异常，基本就是没有可用的识别服务。
  Future<String?> _resolveChineseLocale() async {
    try {
      final locales = await _speech.locales();
      if (locales.isEmpty) return null;
      for (final l in locales) {
        final low = l.localeId.toLowerCase().replaceAll('_', '-');
        if (low == 'zh-cn' || low == 'zh-hans-cn' || low == 'cmn-hans-cn') {
          return l.localeId;
        }
      }
      for (final l in locales) {
        if (l.localeId.toLowerCase().startsWith('zh')) return l.localeId;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> start({
    required void Function(String text, bool isFinal) onResult,
    void Function(String message, AsrFailure kind)? onError,
    void Function()? onStopped,
    String? localeId,
  }) async {
    final ok = await init();
    if (!ok) {
      // 有权限但初始化失败 → 没有语音服务；没权限 → 权限问题
      final bool hasPerm = await _safeHasPermission();
      onError?.call(
        hasPerm ? 'no_engine' : 'no_permission',
        hasPerm ? AsrFailure.noEngine : AsrFailure.noPermission,
      );
      onStopped?.call();
      return;
    }

    _errorCb = onError;
    _stoppedCb = onStopped;
    _gotAnyText = false;
    _stoppedReported = false;

    // 调用方指定了就尊重；否则按设备支持情况挑一个中文标签。
    // 注意：7.x 里 localeId 属于 SpeechListenOptions，
    // 顶层那套同名参数标了 @Deprecated，不要再混用。
    final String? resolved = localeId ?? await _resolveChineseLocale();
    if (resolved == null) {
      // 有识别服务但没有中文 → 说中文必然识别不出，提前告知
      onError?.call('no_chinese', AsrFailure.noEngine);
      onStopped?.call();
      return;
    }

    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          final text = result.recognizedWords;
          if (text.trim().isNotEmpty) {
            _gotAnyText = true;
            _watchdog?.cancel();
            _watchdog = null;
          }
          onResult(text, result.finalResult);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          // 出错不自动取消会话，错误交给上层提示，用户还能点「说完了」
          cancelOnError: false,
          // confirmation 模式在国产 ROM 上兼容性最好；dictation 多家不支持
          listenMode: ListenMode.confirmation,
          autoPunctuation: false,
          // 停顿 3 秒自动断句：老人说话慢，别太早截断
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 45),
          // 只用系统自带识别（false = 允许联网识别）。
          // 不强制 true：很多国产 ROM 没有离线中文包，强制 on-device 会直接失败。
          onDevice: false,
          localeId: resolved,
          // 药名偏置：Android 13+ 映射到 EXTRA_BIASING_STRINGS，iOS 走 contextualStrings。
          // 「氨氯地平」被听成「安绿地平」是最高频的错误来源，给几个高频词做锚点。
          contextualPhrases: _drugVocabulary,
        ),
      );
    } catch (e) {
      // listen() 在未初始化 / 平台异常时会抛，上层需要知道，不能静默
      onError?.call('$e', AsrFailure.other);
      _reportStopped();
      return;
    }

    // 看门狗：兜住「listen 返回了但服务没真的起来」的情况。
    // 插件 startListening 是 handler.post 异步执行，result.success(true) 却同步返回，
    // 所以「listen 成功」并不等于「真的在收音」。
    _watchdog?.cancel();
    _watchdog = Timer(_watchdogTimeout, () {
      if (!_gotAnyText && !_stoppedReported) {
        _errorCb?.call('watchdog_timeout', AsrFailure.heardNothing);
        _reportStopped();
        _speech.cancel();
      }
    });
  }

  /// 药名偏置词表：只放高频通用名，宁少勿多
  ///
  /// 偏置词给太多反而会盖过用户真实说的话，所以严格限制在这个域里最常见的十几个。
  static const List<String> _drugVocabulary = <String>[
    '氨氯地平',
    '硝苯地平',
    '缬沙坦',
    '厄贝沙坦',
    '美托洛尔',
    '二甲双胍',
    '阿托伐他汀',
    '阿司匹林',
    '氯吡格雷',
    '奥美拉唑',
    '左甲状腺素',
    '布洛芬',
  ];

  Future<bool> _safeHasPermission() async {
    try {
      return await _speech.hasPermission;
    } catch (_) {
      return false;
    }
  }

  void _reportStopped() {
    if (_stoppedReported) return;
    _stoppedReported = true;
    _watchdog?.cancel();
    _watchdog = null;
    _stoppedCb?.call();
  }

  @override
  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    await _speech.stop();
  }

  @override
  Future<void> cancel() async {
    _watchdog?.cancel();
    _watchdog = null;
    _stoppedReported = true;
    await _speech.cancel();
  }

  /// 插件错误码 → 失败类型
  ///
  /// 错误码来自 Kotlin 侧 `onError()` 的映射表：
  /// error_audio_error / error_client / error_permission / error_network /
  /// error_network_timeout / error_no_match / error_busy / error_server /
  /// error_speech_timeout / error_language_not_supported /
  /// error_language_unavailable / error_server_disconnected /
  /// error_too_many_requests / error_unknown
  static AsrFailure _classify(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('language_not_supported') ||
        s.contains('language_unavailable') ||
        s.contains('recognizer_not_available') ||
        s.contains('recognizernotavailable')) {
      return AsrFailure.noEngine;
    }
    if (s.contains('permission')) return AsrFailure.noPermission;
    if (s.contains('no_match') ||
        s.contains('speech_timeout') ||
        s.contains('done_no_result') ||
        s.contains('watchdog')) {
      return AsrFailure.heardNothing;
    }
    return AsrFailure.other;
  }
}
