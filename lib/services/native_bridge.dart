import 'dart:io';

import 'package:flutter/services.dart';

/// 原生侧能力桥：MethodChannel `med_reminder/native`
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.5.0 新增。承载三块 Dart/插件层做不到的事：
/// ═══════════════════════════════════════════════════════════════════
///
/// 1. **系统语音对话框**（语音修复的关键兜底）
///    speech_to_text 插件走 `SpeechRecognizer.createSpeechRecognizer()`
///    服务连接 + 回调，这在 vivo/iQOO 的定制语音服务上不稳定。
///    而 `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` 是系统标准 Intent，
///    由「当前默认语音引擎」弹一个带麦克风的对话框，说完把文字返回。
///    微信语音转文字、大量主流 App 都用这一条路径 —— 它不依赖插件
///    自己去连服务，兼容性远好于前者。
///
/// 2. **循环响铃**（到点持续响，直到用户处理）
///    通知渠道的铃声只播一遍，这是 Android 通知系统的固有行为。
///    「一直响到吃药」只能由我们自己在响铃页用 MediaPlayer
///    (setLooping) + Vibrator(循环波形) 实现。
///
/// 3. **电池优化白名单**（后台/被杀收不到通知的主要解法）
///    vivo「后台高耗电/速冻」会冻结应用并取消第三方 App 的闹钟。
///    `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 是标准豁免入口，
///    需要在 manifest 声明 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限。
class NativeBridge {
  NativeBridge._();
  static const MethodChannel _ch = MethodChannel('med_reminder/native');

  static bool get supported => Platform.isAndroid;

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
      // 设备上没有任何语音引擎时，系统会直接回错 —— 调用方按「无服务」处理
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
