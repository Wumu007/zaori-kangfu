import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// 原生录到的一段音频（在线识别用）
class CapturedAudio {
  const CapturedAudio({this.pcm, this.hasSpeech = false, this.error});

  /// 16k / 单声道 / 16bit PCM
  final Uint8List? pcm;

  /// 是否检测到人声（false 说明用户没开口）
  final bool hasSpeech;

  /// 录音失败原因
  final String? error;

  bool get isEmpty => error != null || pcm == null || pcm!.isEmpty;
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

  /// 原生通知被点开（第二通道发的通知不带 fln 的 payload 回调，
  /// 只能由原生主动告诉 Dart「有 payload 可取」）
  static final StreamController<void> _ringingCtrl =
      StreamController<void>.broadcast();

  static bool _handlerBound = false;

  /// 正在等待的那次录音（原生录完会回调 onlineAudio）
  static Completer<CapturedAudio>? _pendingCapture;

  /// 原生识别事件流（ready / partial / result / error / endOfSpeech）
  static Stream<NativeAsrEvent> get asrEvents => _asrCtrl.stream;

  /// 「原生通知被点开了」事件流。收到后调用 [takePendingPayload] 取 payload。
  static Stream<void> get ringingRequests => _ringingCtrl.stream;

  /// 绑定原生 → Dart 的回调通道。
  /// 只需在首次使用语音前调用一次（重复调用无副作用）。
  static void bindAsrHandler() {
    if (_handlerBound) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'ringingPayload') {
        _ringingCtrl.add(null);
        return null;
      }
      if (call.method == 'onlineAudio') {
        final Map<Object?, Object?> a =
            (call.arguments as Map<Object?, Object?>?) ??
                const <Object?, Object?>{};
        final Object? rawPcm = a['pcm'];
        Uint8List? pcm;
        if (rawPcm is Uint8List) {
          pcm = rawPcm;
        } else if (rawPcm is List<int>) {
          pcm = Uint8List.fromList(rawPcm);
        }
        final Completer<CapturedAudio>? pending = _pendingCapture;
        _pendingCapture = null;
        pending?.complete(CapturedAudio(
          pcm: pcm,
          hasSpeech: (a['hasSpeech'] as bool?) ?? false,
          error: a['error'] as String?,
        ));
        return null;
      }
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

  // ------------------------------------------------ 在线识别：录一句

  /// 录一句 16k PCM 交给上层上传。
  ///
  /// 原生侧自带断句：检测到人声后安静 1.2 秒即结束；一直没开口则 6 秒
  /// 自动结束；最长 15 秒。所以这个方法会「阻塞到用户说完」，调用方
  /// 不需要自己计时。
  ///
  /// 返回 null 表示平台不支持或原生拒绝启动。
  static Future<CapturedAudio?> recordUtterance({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!supported) return null;
    bindAsrHandler();
    if (_pendingCapture != null) return null;

    final Completer<CapturedAudio> c = Completer<CapturedAudio>();
    _pendingCapture = c;
    final bool started =
        await _ch.invokeMethod<bool>('startOnlineRecord') ?? false;
    if (!started) {
      _pendingCapture = null;
      return null;
    }

    try {
      return await c.future.timeout(
        timeout,
        onTimeout: () {
          unawaited(stopOnlineRecord());
          return const CapturedAudio(error: '录音超时');
        },
      );
    } finally {
      if (identical(_pendingCapture, c)) _pendingCapture = null;
    }
  }

  /// 提前结束录音（用户点「说完了」）
  static Future<void> stopOnlineRecord() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('stopOnlineRecord');
    } catch (_) {}
  }

  // ------------------------------------------------ 离线识别（Vosk）

  /// APK 里是否带了离线中文模型。
  ///
  /// V1.9.0 起，语音识别不再依赖系统服务：模型随 APK 一起下发，
  /// 首次使用时解压到应用目录，之后完全离线识别。
  static Future<bool> get offlineAsrHasModel async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('offlineAsrHasModel') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 启动离线识别。
  ///
  /// 立即返回 true 表示任务已下发；真正的进度与结果通过 [asrEvents]
  /// 推送，type 以 `offline_` 开头（offline_ready / offline_partial /
  /// offline_result / offline_error / offline_end）。
  /// 首次启动会解压模型，可能等 3–5 秒才收到 offline_ready。
  static Future<bool> startOfflineAsr() async {
    if (!supported) return false;
    bindAsrHandler();
    try {
      return await _ch.invokeMethod<bool>('startOfflineAsr') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopOfflineAsr() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('stopOfflineAsr');
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

  // ------------------------------------------------ 第二通道排程

  /// 把未来提醒表交给原生，由原生用自己的 AlarmManager 再排一批
  ///
  /// 为什么要有两条通道：用户日志证明权限、白名单、排程全都正常，
  /// 但插件那批 alarm 在后台会被系统拦掉。两条独立通道互为备份，
  /// 任一触发都会发同 id 的通知（不会重复出现）。
  static Future<void> setGuardSchedule(String json) async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<bool>(
        'setGuardSchedule',
        <String, Object?>{'json': json},
      );
    } catch (_) {}
  }

  /// 排一条原生测试闹钟（设置页「测试提醒」）
  ///
  /// 让测试也走第二通道：原生 alarm → 原生 receiver →
  /// （有悬浮窗权限时）直接弹响铃页。这样测的就是真实的后台链路。
  static Future<bool> setTestAlarm({
    required int seconds,
    required String payload,
    String title = '测试提醒',
    String body = '',
    int id = 990001,
  }) async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('setTestAlarm', <String, Object?>{
            'seconds': seconds,
            'id': id,
            'payload': payload,
            'title': title,
            'body': body,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------ 悬浮窗权限

  /// 是否已获得「显示在其他应用上层」权限
  ///
  /// 这是「切到别的应用/后台也能弹出响铃界面」的关键：
  /// 持有它，系统才允许后台 startActivity。
  static Future<bool> get canDrawOverlays async {
    if (!supported) return true;
    try {
      return await _ch.invokeMethod<bool>('canDrawOverlays') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「语音输入 / 语音服务」设置页
  static Future<void> openVoiceInputSettings() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('openVoiceInputSettings');
    } catch (_) {}
  }

  /// 跳系统页申请悬浮窗权限
  static Future<void> requestOverlayPermission() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('requestOverlayPermission');
    } catch (_) {}
  }

  /// 取「原生通知点开时带来的 payload」
  static Future<String?> takePendingPayload() async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<String>('takePendingPayload');
    } catch (_) {
      return null;
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
