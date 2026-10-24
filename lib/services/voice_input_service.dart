import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medication_draft.dart';
import 'app_log.dart';
import 'app_settings.dart';
import 'asr_engine.dart';
import 'medication_nlu.dart';
import 'native_bridge.dart';
import 'tencent_asr.dart';

// 页面只依赖编排层，不该再单独 import 引擎实现；
// 把失败类型枚举透出去，页面才写得出 `kind == AsrFailure.noEngine`
export 'asr_engine.dart' show AsrFailure;

/// 语音录入的结果：申请麦克风这一步是否成功
///
/// 单独一个枚举而不是 bool，因为「被拒」和「永久拒绝」要给不同的引导：
/// 前者再点一次还会弹系统框，后者只能去系统设置里手动开。
enum MicGate { ok, denied, permanentlyDenied }

/// 收音走的三条路径（日志里用来定位「到底哪条通了」）
class VoicePath {
  VoicePath._();
  static const String online = 'N-在线识别';
  static const String offline = 'O-离线模型';
  static const String native = 'B-原生识别器';
  static const String plugin = 'A-插件';
  static const String dialog = 'C-系统对话框';
}

/// 离线路径的结果
///
/// 为什么不用 `String?`：需要区分两种「没拿到文字」——
/// - `text` 为空 + `failure` 为空 = 用户没说话 / 没听清 → 提示重说；
/// - `failure` 非空 = 引擎本身不可用（模型解压失败、麦克风被占）→
///   必须说清原因，否则用户会一直对着手机重复说话。
/// 在线路径的结果
///
/// 与离线那边一样要区分「没听到」和「引擎不可用」：
/// - text 有值 → 成功；
/// - failure 非空 + networkProblem=false → 密钥/开通/额度问题，回落也没用；
/// - failure 非空 + networkProblem=true → 网络/麦克风问题，可以回落离线。
class _OnlineOutcome {
  const _OnlineOutcome({this.text, this.failure, this.networkProblem = false});

  final String? text;
  final String? failure;
  final bool networkProblem;
}

class _OfflineOutcome {
  const _OfflineOutcome({this.text, this.failure});

  final String? text;
  final String? failure;
}

/// 语音录入的编排层：**听 → 解析 → 回读**
///
/// ═══════════════════════════════════════════════════════════════════
/// V1.6.0：三重路径（第四个版本，不再赌单一路径）
/// ═══════════════════════════════════════════════════════════════════
///
/// 历史：V1.3 插件静默监听 → 不通；V1.4 按插件源码修完 4 个确定缺陷
/// → 仍不通；V1.5 加系统对话框兜底 → 用户反馈仍不可用。
///
/// 三轮下来可以确定：**speech_to_text 插件在这台 iQOO 上的服务连接
/// 就是不通**，而系统对话框需要用户手动点开、部分 ROM 上也失败。
///
/// 所以这一版按「成功率从高到低」串三条路，任一条拿到文字就结束：
///
/// 1. **B · 原生识别器**（优先）
///    直接在 MainActivity 里调 `SpeechRecognizer.createSpeechRecognizer`
///    + 自己的 RecognitionListener，绕开插件全部封装。这条路的代码
///    完全在我们手里，出问题日志能指到具体某一行。
///
/// 2. **A · 插件** —— 原生也失败时再试插件（换一种实现碰运气）。
///
/// 3. **C · 系统对话框** —— 最后兜底：弹微信同款系统语音窗口。
///
/// 三条都失败才判定不可用，全程写进 [AppLog]，
/// 用户可从「我的 → 运行日志」导出。
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

  /// 开始收音：B → A → C 依次尝试，拿到文字即停
  ///
  /// 返回 false 表示三条路都没拿到文字，此时 [onError] 已带人话说明。
  /// [onFinal] 会因多段断句被调用多次，调用方负责拼接。
  /// [onStopped] 在整个流程结束时回调（UI 靠它退出收音态）。
  Future<bool> start({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(String readableError) onError,
    /// 过程状态（「正在准备模型」「请说话」），与识别文字分开，
    /// 免得这些提示被当成识别结果填进输入框
    void Function(String status)? onStatus,
    void Function(MicGate gate)? onMicBlocked,
    void Function()? onStopped,
    void Function(AsrFailure kind, String readableError)? onFailure,
  }) async {
    final AppLog logx = AppLog.instance;
    logx.voice('══ 语音会话开始 ══', 'app=${logx.sessionId}');

    final MicGate mic = await ensureMic();
    logx.voice('麦克风权限', '$mic');
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

    // ═══════════════════════════════════════════════════════════════
    // 路径 N：在线识别（V1.11.0，用户在设置页配置密钥后启用）
    // ═══════════════════════════════════════════════════════════════
    //
    // 腾讯云的一句话识别 = 微信语音转文字同一套服务，对药名的准确率
    // 明显高于本地小模型。默认关闭，只有用户自己填了密钥并打开才走。
    //
    // 失败分两类处理：
    // - 密钥/开通/额度问题 → 直接说清原因（回落也没用，别让用户白说）；
    // - 网络/麦克风问题 → 回落本地离线识别，并提示「请再说一次」。
    final AppSettings cfg = AppSettings.instance;
    if (cfg.asrOnlineReady) {
      final _OnlineOutcome on = await _tryOnlinePath(
        onStatus: onStatus,
        onPartial: onPartial,
      );
      if (on.text != null && on.text!.trim().isNotEmpty) {
        logx.voice('成功路径', VoicePath.online);
        onFinal(on.text!.trim());
        onStopped?.call();
        return true;
      }
      // 在线确实听完了、但没内容（没说话 / 没识别出字）：
      // 不能再往下回落 —— 那会立刻又开一次录音，用户会觉得莫名其妙。
      if (on.failure == null) {
        logx.voice('在线没拿到内容', '按没听清处理');
        const String msg = '没有听清。靠近一点、说慢一点再试一次，'
            '比如「氨氯地平一片，每天早八点」。';
        onError(msg);
        onFailure?.call(AsrFailure.heardNothing, msg);
        onStopped?.call();
        return false;
      }

      // 密钥 / 开通 / 额度问题：回落也没用，直接说清原因
      if (!on.networkProblem) {
        logx.voice('在线识别不可用', on.failure!);
        onError(on.failure!);
        onFailure?.call(AsrFailure.noEngine, on.failure!);
        onStopped?.call();
        return false;
      }

      // 网络或麦克风问题 → 回落本地离线识别
      logx.voice('在线失败，回落本地', on.failure ?? '未知原因');
      onStatus?.call('网络没通，改用本地识别…');
      // 原生刚释放 AudioRecord，给系统一点时间再开第二次录音，
      // 否则偶发「麦克风打不开」
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // ═══════════════════════════════════════════════════════════════
    // 路径 O：离线模型（V1.9.0 起的主路径）
    // ═══════════════════════════════════════════════════════════════
    //
    // 用户设备的系统语音服务「注册了但不干活」，B/A/C 三条全靠系统，
    // 日志已证实全废（error code=8 / 1.2 秒 done / 对话框 4 毫秒返回）。
    //
    // 因此：**只要 APK 里带了模型，就只走离线这一条**。
    // 失败也不再往下试系统路径 —— 那只会让用户多等 11 秒再看到
    // 同样的失败提示，体验更差。
    final bool hasOffline = await NativeBridge.offlineAsrHasModel;
    logx.voice('离线模型可用', '$hasOffline');

    if (hasOffline) {
      final _OfflineOutcome o = await _tryOfflinePath(
        onPartial: onPartial,
        onFinal: onFinal,
        onStatus: onStatus,
      );
      if (o.text != null && o.text!.trim().isNotEmpty) {
        logx.voice('成功路径', VoicePath.offline);
        onStopped?.call();
        return true;
      }

      // 引擎层问题（模型没准备好 / 麦克风被占）：给准确原因，
      // 不要用「没听清」——那会让用户反复对着手机重复同一句话。
      final String? f = o.failure;
      if (f != null) {
        const String head = '语音没准备好';
        final String msg = '$head：$f';
        onError(msg);
        onFailure?.call(AsrFailure.noEngine, msg);
        onStopped?.call();
        return false;
      }

      const String msg = '没有听清。靠近一点、说慢一点再试一次，'
          '比如「氨氯地平一片，每天早八点」。';
      onError(msg);
      onFailure?.call(AsrFailure.heardNothing, msg);
      onStopped?.call();
      return false;
    }

    // 没有打包模型（理论上不会发生）→ 退回系统路径
    // ---- 路径 B：原生识别器（代码可控）----
    final String? b = await _tryNativePath(onPartial: onPartial, onFinal: onFinal);
    if (b != null && b.trim().isNotEmpty) {
      logx.voice('成功路径', VoicePath.native);
      onStopped?.call();
      return true;
    }

    // ---- 路径 A：插件 ----
    final String? a = await _tryPluginPath(onPartial: onPartial, onFinal: onFinal);
    if (a != null && a.trim().isNotEmpty) {
      logx.voice('成功路径', VoicePath.plugin);
      onStopped?.call();
      return true;
    }

    // ---- 路径 C：系统对话框（用户看得见，最后兜底）----
    final String? c = await _tryDialogPath(onFinal: onFinal);
    if (c != null && c.trim().isNotEmpty) {
      logx.voice('成功路径', VoicePath.dialog);
      onStopped?.call();
      return true;
    }

    // ---- 三条都失败 ----
    final List<String> services = await NativeBridge.speechServices();
    logx.voice('全部路径失败', '系统语音服务=[${services.join(',')}]');
    final String msg = services.isEmpty
        ? '这台手机没有可用的语音识别服务。\n用下面的键盘输入一样快。'
        : '语音没有收到内容。\n可以再说一次，或用下面的键盘输入。';
    onError(msg);
    onFailure?.call(AsrFailure.noEngine, msg);
    onStopped?.call();
    return false;
  }

  // ------------------------------------------------------------ 路径 N

  /// 在线识别：录一句 → 上传腾讯云 → 拿文字
  ///
  /// 录音与断句都在原生侧完成（有声才录、安静 1.2 秒即结束），
  /// 这里只负责等待与上传，所以整段耗时 = 说话时长 + 约 0.5 秒。
  Future<_OnlineOutcome> _tryOnlinePath({
    void Function(String status)? onStatus,
    void Function(String partialText)? onPartial,
  }) async {
    final AppLog logx = AppLog.instance;
    if (!Platform.isAndroid) return const _OnlineOutcome();

    onStatus?.call('请说话…');
    final CapturedAudio? cap = await NativeBridge.recordUtterance();

    if (cap == null) {
      logx.voice('在线录音没启动');
      return const _OnlineOutcome(
        failure: '麦克风没能启动',
        networkProblem: true,
      );
    }
    if (cap.error != null) {
      logx.voice('在线录音出错', cap.error!);
      return _OnlineOutcome(failure: cap.error, networkProblem: true);
    }
    // V1.12.0：**不再「因为没检测到人声就丢弃录音」**。
    // 本地 VAD 只是在猜；猜错了直接把整段扔掉，用户看到的就是
    // 「说完了没反应」（日志里 11 次有 8 次死在这里）。
    // 现在只要录到有声音频就发给腾讯云，由真正干活的模型决定听没听到；
    // 静音/噪声最多浪费一次免费额度，但成功率高得多。
    if (cap.pcm == null || cap.pcm!.length < 3200) {
      logx.voice('在线录音太短', '${cap.pcm?.length ?? 0} 字节，未上传');
      return const _OnlineOutcome();
    }

    final int ms = cap.pcm!.length ~/ 32;
    logx.voice(
      '在线录音完成',
      '$ms 毫秒 / 峰值 ${cap.peak.toStringAsFixed(0)} / 人声=${cap.hasSpeech}',
    );
    onStatus?.call('正在识别…');

    final AsrOnlineResult r = await TencentAsr.recognize(cap.pcm!);
    if (r.ok) {
      logx.voice('在线识别结果', r.text.isEmpty ? '（没听出内容）' : r.text);
      return _OnlineOutcome(text: r.text);
    }
    return _OnlineOutcome(
      failure: r.error,
      // 鉴权/开通类问题不算网络问题 —— 回落离线只会让用户白说一遍
      networkProblem: r.networkProblem && !r.authProblem,
    );
  }

  // ------------------------------------------------------------ 路径 O

  /// 离线识别（Vosk，模型随 APK 下发）
  ///
  /// 交互按「准备 → 说话 → 停顿自动收尾」三段设计：
  /// - 准备阶段的状态走 [onStatus]，不写进输入框；
  /// - 说完全自动（停顿 3 秒）收尾，不用等超时；
  /// - 15 秒还没动静就兜底结束，避免一直占着麦克风。
  Future<_OfflineOutcome> _tryOfflinePath({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
    void Function(String status)? onStatus,
  }) async {
    final AppLog logx = AppLog.instance;
    if (!Platform.isAndroid) {
      return const _OfflineOutcome(failure: '仅支持 Android');
    }

    if (!await NativeBridge.offlineAsrHasModel) {
      logx.voice('路径O 跳过', 'APK 内没有离线模型');
      return const _OfflineOutcome();
    }

    final Completer<_OfflineOutcome> done = Completer<_OfflineOutcome>();
    String text = '';
    String? failure;
    bool ready = false;
    StreamSubscription<NativeAsrEvent>? sub;
    Timer? timeout;
    Timer? silence;

    void finish(String? v) {
      if (!done.isCompleted) {
        done.complete(_OfflineOutcome(
          text: (v == null || v.trim().isEmpty) ? null : v,
          failure: failure,
        ));
      }
    }

    // 说完停顿 3 秒就收尾：老人说完一句会停一下，
    // 这比让界面干等 15 秒友好得多；3 秒也够留出换气的间隙
    void armSilence() {
      silence?.cancel();
      silence = Timer(const Duration(milliseconds: 3000), () {
        if (text.trim().isEmpty) return;
        logx.voice('路径O 停顿收尾', text.trim());
        finish(text);
        unawaited(NativeBridge.stopOfflineAsr());
      });
    }

    NativeBridge.bindAsrHandler();
    sub = NativeBridge.asrEvents.listen((NativeAsrEvent e) {
      if (!e.type.startsWith('offline_')) return;
      final String kind = e.type.substring('offline_'.length);
      switch (kind) {
        case 'detail':
          // 原生把「复用已解压模型 / 解压 12 个文件 70MB / 加载失败原因」
          // 都写在这一条里，出问题一眼能看出来
          logx.voice('路径O 准备', e.text);
          break;
        case 'progress':
          logx.voice('路径O 进度', e.text);
          onStatus?.call(e.text);
          break;
        case 'ready':
          ready = true;
          logx.voice('路径O 模型就绪', '可以说话了');
          onStatus?.call('请说话…');
          break;
        case 'partial':
          if (e.text.trim().isEmpty) break;
          text = e.text;
          onStatus?.call('正在听…');
          onPartial(e.text);
          armSilence();
          break;
        case 'result':
          logx.voice('路径O 最终结果', e.text);
          text = e.text;
          if (e.text.trim().isNotEmpty) onFinal(e.text.trim());
          finish(text);
          break;
        case 'error':
          failure = e.text.isEmpty ? '识别引擎报错' : e.text;
          logx.voice('路径O 错误', '${e.text} code=${e.code}');
          finish(text);
          break;
        case 'end':
          logx.voice('路径O 会话结束', '累计 ${text.trim().length} 字');
          finish(text);
          break;
      }
    });

    final bool started = await NativeBridge.startOfflineAsr();
    if (!started) {
      logx.voice('路径O 启动失败', '原生拒绝启动');
      await sub.cancel();
      // 原生会推一条 offline_error 说明原因；这里只兜底
      return _OfflineOutcome(failure: failure ?? '语音引擎没能启动');
    }
    onStatus?.call('正在准备语音模型…');

    timeout = Timer(const Duration(seconds: 15), () {
      logx.voice('路径O 超时', ready ? '已就绪但没听到内容' : '15 秒仍在准备');
      if (!ready) failure = '模型准备超时（首次需解压，请再试一次）';
      finish(text);
    });

    final _OfflineOutcome r = await done.future;
    timeout.cancel();
    silence?.cancel();
    await sub.cancel();
    await NativeBridge.stopOfflineAsr();
    return r;
  }

  // ------------------------------------------------------------ 路径 B

  /// 原生识别器：MainActivity 的 SpeechRecognizer，事件经 MethodChannel 回传
  ///
  /// 超时 7 秒：给出足够时间说一句话，又不至于让用户干等太久。
  /// 三条路径是串联的，每条超时都会累加到用户等待时间里。
  Future<String?> _tryNativePath({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
  }) async {
    final AppLog logx = AppLog.instance;
    if (!Platform.isAndroid) {
      logx.voice('路径B 跳过', '非 Android');
      return null;
    }
    if (!await NativeBridge.nativeAsrAvailable) {
      logx.voice('路径B 不可用', '系统无识别服务');
      return null;
    }

    final Completer<String?> done = Completer<String?>();
    String buf = '';
    StreamSubscription<NativeAsrEvent>? sub;
    Timer? timeout;

    void finish(String? v) {
      if (!done.isCompleted) done.complete(v);
    }

    NativeBridge.bindAsrHandler();
    sub = NativeBridge.asrEvents.listen((NativeAsrEvent e) {
      // 离线路径的事件也走同一个通道，这里必须过滤掉
      if (e.type.startsWith('offline_')) return;
      if (e.isResult || e.isError || e.isEnd || e.text.isNotEmpty) {
        logx.voice('路径B 事件', '${e.type} "${e.text}" code=${e.code}');
      }
      if (e.isPartial) onPartial(e.text);
      if (e.isResult) {
        buf = e.text;
        if (e.text.trim().isNotEmpty) onFinal(e.text.trim());
        finish(buf);
      } else if (e.isError) {
        // 错误码：6=SPEECH_TIMEOUT 7=NO_MATCH 1/2=网络
        // 9=权限不足 10/11=服务不可用。有部分文字也算成功。
        finish(buf.trim().isEmpty ? null : buf);
      }
    });

    final bool started = await NativeBridge.startNativeAsr();
    if (!started) {
      logx.voice('路径B 启动失败');
      await sub.cancel();
      return null;
    }
    logx.voice('路径B 已开始收音');

    timeout = Timer(const Duration(seconds: 7), () {
      logx.voice('路径B 超时', '7 秒');
      finish(buf.trim().isEmpty ? null : buf);
    });

    final String? r = await done.future;
    timeout.cancel();
    await sub.cancel();
    await NativeBridge.stopNativeAsr();
    return r;
  }

  // ------------------------------------------------------------ 路径 A

  /// 插件路径：speech_to_text（先 init，再 listen）
  Future<String?> _tryPluginPath({
    required void Function(String partialText) onPartial,
    required void Function(String finalText) onFinal,
  }) async {
    final AppLog logx = AppLog.instance;

    bool ready = false;
    try {
      ready = await _engine
          .init()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
    } catch (e, st) {
      logx.error('路径A init', e, st);
    }
    logx.voice('路径A 插件初始化', ready ? '成功' : '失败或超时');
    if (!ready) return null;

    final Completer<String?> done = Completer<String?>();
    String buf = '';
    Timer? timeout;

    // V1.7.0：start() 内部可能卡在插件的 locales() 上（用户日志已证实），
    // 这里再套一层 5 秒硬超时 —— 无论插件怎么闹，都必须让流程回到
    // 调用方，否则后面的「系统语音对话框」永远轮不到。
    try {
      await _engine.start(
        onResult: (String text, bool isFinal) {
          if (text.trim().isEmpty) return;
          logx.voice(isFinal ? '路径A 最终结果' : '路径A 部分结果', text);
          if (isFinal) {
            buf += text;
            onFinal(text.trim());
          } else {
            onPartial(text.trim());
          }
        },
        onError: (String message, AsrFailure kind) {
          logx.voice('路径A 错误', '$kind | $message');
        },
        onStopped: () {
          logx.voice('路径A 会话结束', '累计 ${buf.trim().length} 字');
          if (!done.isCompleted) {
            done.complete(buf.trim().isEmpty ? null : buf);
          }
        },
      ).timeout(const Duration(seconds: 5), onTimeout: () {
        logx.voice('路径A start 超时', '5 秒未返回');
      });
      logx.voice('路径A listen 已下发');
    } catch (e, st) {
      logx.error('路径A start 异常', e, st);
      if (!done.isCompleted) done.complete(null);
    }

    timeout = Timer(const Duration(seconds: 4), () {
      logx.voice('路径A 超时', '4 秒');
      if (!done.isCompleted) {
        done.complete(buf.trim().isEmpty ? null : buf);
      }
    });

    final String? r = await done.future;
    timeout.cancel();
    await _engine.cancel();
    return r;
  }

  // ------------------------------------------------------------ 路径 C

  /// 系统对话框：微信同款，用户看得见地说一句
  Future<String?> _tryDialogPath({
    required void Function(String finalText) onFinal,
  }) async {
    final AppLog logx = AppLog.instance;
    logx.voice('路径C 打开系统语音对话框');
    final String? text = await NativeBridge.showSystemSpeechDialog();
    logx.voice('路径C 返回', text == null ? '无文字' : '${text.length} 字');
    if (text != null && text.trim().isNotEmpty) {
      onFinal(text.trim());
      return text;
    }
    return null;
  }

  // ------------------------------------------------------------ 其它

  Future<void> stop() async {
    // 「说完了」按钮：两条路都要能立刻收尾
    await NativeBridge.stopOnlineRecord();
    await NativeBridge.stopOfflineAsr();
    await _engine.stop();
  }

  Future<void> cancel() async {
    await NativeBridge.stopOnlineRecord();
    await NativeBridge.stopOfflineAsr();
    await NativeBridge.stopNativeAsr();
    await _engine.cancel();
  }

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
    await NativeBridge.stopNativeAsr();
    await _engine.cancel();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// 系统错误码 → 老人能听懂的一句话
  static String humanizeError(String raw, [AsrFailure? kind]) =>
      _humanizeError(raw, kind);

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
