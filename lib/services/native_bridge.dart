import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 原生语音识别器抛给 Dart 的一个事件
class NativeAsrEvent {
  const NativeAsrEvent({
    required this.type,
    required this.text,
    required this.code,
  });

  /// ready / speaking / partial / result / error / endOfSpeech
  final String type;
  final String text;

  /// Android SpeechRecognizer 的错误码（type == 'error' 时有意义）
  final int code;

  bool get isResult => type == 'result';
  bool get isPartial => type == 'partial';
  bool get isError => type == 'error';
  bool get isEnd => type == 'endOfSpeech';
}

/// 原生侧能力桥：MethodChannel `med_reminder/native`
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.6.0 起承载五块 Dart/插件层做不到或做不好的事：
/// ═══════════════════════════════════════════════════════════════════
///
/// 1. **原生语音识别器**（`SpeechRecognizer` 直接调用）
///    speech_to_text 插件在 iQOO 上连续三版不工作（它自己的服务连接
///    与回调封装存在兼容问题）。这一版绕开插件，用官方 API 自己实现，
///    结果通过 [asrEvents] 事件流推回 Dart。
///
/// 2. **系统语音对话框**（`ACTION_RECOGNIZE_SPEECH`）
///    微信语音转文字同款，由当前默认语音引擎弹标准麦克风窗口。
///    作为最后的兜底 —— 前两条静默路径都不行时，让用户「看得见」地
///    说一句。
///
/// 3. **后台守护前台服务** —— 「只在 App 界面里能提醒」的解法。
///    前台服务优先级等同前台 App，系统不会轻易冻结，已排的闹钟
///    才不会被 ROM 一并清掉。
///
/// 4. **循环响铃**（MediaPlayer loop + Vibrator 循环波形）。
///
/// 5. **电池优化白名单** + 屏幕常亮。
class NativeBridge {
  NativeBridge._();
  static const MethodChannel _ch = MethodChannel('med_reminder/native');

  static bool get supported => Platform.isAndroid;

  // ------------------------------------------------ 原生语音识别器事件

  static final StreamController<NativeAsrEvent> _asrCtrl =
      StreamController<NativeAsrEvent>.broadcast();

  static bool _handlerBound = false;

  /// 原生识别事件流（ready / partial / result / error / endOfSpeech）
  static Stream<NativeAsrEvent> get asrEvents => _asrCtrl.stream;

  /// 绑定原生 → Dart 的回调通道。
  /// 只需在首次使用语音前调用一次（重复调用无副作用）。
  static void bindAsrHandler() {
    if (_handlerBound) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'asrEvent') return null;
      final Map<Object?, Object?> args =
          (call.arguments as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
      _asrCtrl.add(NativeAsrEvent(
        type: (args['type'] as String?) ?? '',
        text: (args['text'] as String?) ?? '',
        code: (args['code'] as int?) ?? 0,
      ));
      return null;
    });
  }

  /// 是否有可用的系统语音识别服务（原生侧判断）
  static Future<bool> get nativeAsrAvailable async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('nativeAsrAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 启动原生静默识别。返回是否成功启动。
  static Future<bool> startNativeAsr({String language = 'zh-CN'}) async {
    if (!supported) return false;
    bindAsrHandler();
    try {
      return await _ch.invokeMethod<bool>(
            'startNativeAsr',
            <String, Object?>{'language': language},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> stopNativeAsr() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('stopNativeAsr');
    } catch (_) {}
  }

  // ------------------------------------------------ 系统语音对话框

  /// 弹系统「语音输入」对话框，返回识别出的文字；取消/失败返回 null
  static Future<String?> showSystemSpeechDialog({String language = 'zh-CN'}) async {
    if (!supported) return null;
    try {
      final Object? r = await _ch.invokeMethod<Object?>(
        'showSystemSpeechDialog',
        <String, Object?>{'language': language},
      );
      if (r is String && r.trim().isNotEmpty) return r.trim();
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 列出系统里注册的语音识别服务（诊断用）
  static Future<List<String>> speechServices() async {
    if (!supported) return const <String>[];
    try {
      final Object? r = await _ch.invokeMethod<Object?>('speechServices');
      if (r is List) return r.cast<String>();
      return const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  // ------------------------------------------------ 后台守护服务

  /// 启动后台守护前台服务（App 在前台时调用才有效）
  static Future<bool> startGuard() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('startGuard') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopGuard() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('stopGuard');
    } catch (_) {}
  }

  /// 守护服务当前是否在跑
  static Future<bool> get isGuardRunning async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('isGuardRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------ 循环响铃

  /// 开始循环响铃（系统闹钟铃声循环播放 + 长短循环震动）
  static Future<void> ringStart() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('ringStart');
    } catch (_) {}
  }

  static Future<void> ringStop() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('ringStop');
    } catch (_) {}
  }

  static Future<bool> get isRinging async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('isRinging') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------ 屏幕 / 电池

  /// 响铃页保持屏幕常亮（FLAG_KEEP_SCREEN_ON）
  static Future<void> keepScreenOn(bool on) async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('keepScreenOn', <String, Object?>{'on': on});
    } catch (_) {}
  }

  /// 是否已在电池优化白名单里
  static Future<bool> get isIgnoringBatteryOptimizations async {
    if (!supported) return true; // 非 Android 不存在这个问题
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 弹系统对话框请求「忽略电池优化」
  ///
  /// 注意：这是**系统确认框**（用户点「允许」），不是悄悄加白名单，
  /// Google Play 允许闹钟/提醒类 App 申请它，本项目属于该类别。
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!supported) return true;
    try {
      return await _ch.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }
}
