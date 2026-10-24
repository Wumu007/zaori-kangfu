import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'app_log.dart';
import 'app_settings.dart';
import 'drug_vocabulary.dart';

/// 在线识别的一次结果
///
/// 三种情况必须分开，因为给用户的话完全不同：
/// - [ok] = true：拿到了文字（可能为空字符串，表示确实没听到内容）；
/// - [authProblem]：密钥/开通/额度问题 —— 再试一百次也没用，要去控制台处理；
/// - [networkProblem]：网络没通 —— 可以回落本地识别。
class AsrOnlineResult {
  const AsrOnlineResult({
    this.text = '',
    this.error,
    this.errorCode,
    this.authProblem = false,
    this.networkProblem = false,
  });

  final String text;

  /// 给用户看的一句话（null = 成功）
  final String? error;

  /// 腾讯云返回的错误码或本地标记，便于日志排查
  final String? errorCode;

  final bool authProblem;
  final bool networkProblem;

  bool get ok => error == null;
}

/// 腾讯云「一句话识别」
///
/// ═══════════════════════════════════════════════════════════════════
/// 为什么选它（而不是继续折腾系统语音或离线模型）
/// ═══════════════════════════════════════════════════════════════════
///
/// 用户设备的系统语音服务「注册了但不干活」（日志：error code=8、
/// 1.2 秒即 done、系统对话框 4 毫秒返回、系统语音服务=[]），而打包进
/// APK 的离线小模型对药名的识别率也不够看。
///
/// 腾讯云这套就是微信语音转文字用的同一套服务（官方说法字准 97%+），
/// 并且支持「中文医疗」专用引擎和热词表 —— 对「氨氯地平」这种药名
/// 的提升非常直接。
///
/// 关键约束：
/// 1. **密钥由用户自己在设置页填**，绝不写进代码或 APK —— APK 一旦
///    分发出去，内置密钥就等于公开；
/// 2. 单次 ≤60 秒，同步返回几百毫秒，正好适合「说一句话」；
/// 3. 鉴权走 TC3-HMAC-SHA256，纯 Dart 算，不需要任何服务端中转。
class TencentAsr {
  TencentAsr._();

  static const String _host = 'asr.tencentcloudapi.com';
  static const String _service = 'asr';
  static const String _action = 'SentenceRecognition';
  static const String _version = '2019-06-14';
  static const String _contentType = 'application/json; charset=utf-8';

  /// 引擎：中文医疗专用模型。
  ///
  /// 我们说的是药名、剂量、频次，属于医疗域；官方一句话识别支持
  /// 这个取值。若哪天识别异常，可临时换成 '16k_zh'（通用）。
  static const String engine = '16k_zh_medical';

  /// 密钥是否已填齐
  static bool get configured {
    final AppSettings s = AppSettings.instance;
    return s.asrSecretId.trim().isNotEmpty && s.asrSecretKey.trim().isNotEmpty;
  }

  // ------------------------------------------------------------ 对外接口

  /// 识别一段 16k / 单声道 / 16bit 的 PCM
  static Future<AsrOnlineResult> recognize(
    Uint8List pcm, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!configured) {
      return const AsrOnlineResult(
        error: '还没填腾讯云密钥',
        errorCode: 'local_not_configured',
        authProblem: true,
      );
    }
    // 不到 0.1 秒的音频没必要发（也避免白白消耗额度）
    if (pcm.length < 3200) {
      return const AsrOnlineResult(text: '');
    }
    return _post(_body(pcm, _usrKey()), timeout: timeout);
  }

  /// 「测试一下」：不要真音，发 1 秒静音。
  ///
  /// 判据很朴素：**只要能拿到腾讯云的结构化响应，就说明密钥、签名、
  /// 服务开通都没问题**。所以：
  /// - 网络异常 / 鉴权失败 / 未开通 → 失败，并把原因翻译成人话；
  /// - 其余（包括「没识别出内容」这类业务错误）→ 视为连通成功。
  static Future<AsrOnlineResult> testConnection() async {
    if (!configured) {
      return const AsrOnlineResult(
        error: '请先填 SecretId 和 SecretKey',
        errorCode: 'local_not_configured',
        authProblem: true,
      );
    }
    final Uint8List silence = Uint8List(16000 * 2);
    final AsrOnlineResult r =
        await _post(_body(silence, 'selfcheck'), timeout: const Duration(seconds: 15));
    if (r.networkProblem) return r;
    if (r.authProblem) return r;
    return const AsrOnlineResult(text: 'ok');
  }

  // ------------------------------------------------------------ 请求

  static Map<String, Object?> _body(Uint8List pcm, String usrKey) {
    final String hotwords = kDrugVocabulary
        .take(100)
        .map((String w) => '$w|10')
        .join(',');
    return <String, Object?>{
      'ProjectId': 0,
      // 2 = 一句话识别
      'SubServiceType': 2,
      'EngSerViceType': engine,
      // 1 = 直接上传音频数据（而不是给一个 URL）
      'SourceType': 1,
      'VoiceFormat': 'pcm',
      'UsrAudioKey': usrKey,
      'Data': base64Encode(pcm),
      'DataLen': pcm.length,
      // 不要标点（结果要喂给药物解析器，标点会碍事）
      'FilterPunc': 2,
      // 「八点」「一片」智能转成阿拉伯数字，解析更稳
      'ConvertNumMode': 1,
      if (hotwords.isNotEmpty) 'HotwordList': hotwords,
    };
  }

  static String _usrKey() =>
      'u${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  static Future<AsrOnlineResult> _post(
    Map<String, Object?> body, {
    required Duration timeout,
  }) async {
    final AppLog logx = AppLog.instance;
    final int ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String payload = jsonEncode(body);
    final String authorization = _authorization(payload, ts);

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final HttpClientRequest req =
          await client.postUrl(Uri.parse('https://$_host/'));
      req.headers.set(HttpHeaders.contentTypeHeader, _contentType);
      req.headers.set('Authorization', authorization);
      req.headers.set('X-TC-Action', _action);
      req.headers.set('X-TC-Version', _version);
      // 注意：本接口不需要 X-TC-Region，传了反而可能被拒
      req.headers.set('X-TC-Timestamp', '$ts');
      req.add(utf8.encode(payload));

      final HttpClientResponse resp = await req.close().timeout(timeout);
      final String raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final AsrOnlineResult r = _parse(raw);
      logx.voice(
        '在线识别返回',
        r.ok
            ? '${r.text.length} 字 "${r.text}"'
            : '${r.errorCode} | ${r.error}',
      );
      return r;
    } on TimeoutException {
      logx.voice('在线识别超时', '${timeout.inSeconds} 秒');
      return const AsrOnlineResult(
        error: '网络有点慢，没能及时返回',
        errorCode: 'local_timeout',
        networkProblem: true,
      );
    } on SocketException catch (e) {
      logx.voice('在线识别网络异常', '$e');
      return const AsrOnlineResult(
        error: '连不上腾讯云（检查手机网络）',
        errorCode: 'local_network',
        networkProblem: true,
      );
    } on HandshakeException catch (e) {
      logx.voice('在线识别 TLS 异常', '$e');
      return const AsrOnlineResult(
        error: '网络连接不安全（可能被代理拦截）',
        errorCode: 'local_tls',
        networkProblem: true,
      );
    } catch (e) {
      logx.error('在线识别异常', e);
      return AsrOnlineResult(
        error: '识别请求失败：$e',
        errorCode: 'local_exception',
        networkProblem: true,
      );
    } finally {
      client?.close(force: true);
    }
  }

  static AsrOnlineResult _parse(String raw) {
    Map<String, dynamic>? parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      parsed = null;
    }
    if (parsed == null) {
      return const AsrOnlineResult(
        error: '服务返回了看不懂的内容',
        errorCode: 'local_bad_json',
      );
    }
    final Map<String, dynamic> json = parsed;

    final Object? respObj = json['Response'];
    if (respObj is! Map<String, dynamic>) {
      return const AsrOnlineResult(
        error: '服务返回结构异常',
        errorCode: 'local_bad_shape',
      );
    }

    final Object? errObj = respObj['Error'];
    if (errObj is Map) {
      final String code = (errObj['Code'] ?? '').toString();
      return AsrOnlineResult(
        error: _humanize(code),
        errorCode: code,
        authProblem: _isAuthProblem(code),
      );
    }

    final String text = (respObj['Result'] ?? '').toString().trim();
    return AsrOnlineResult(text: text);
  }

  /// 错误码 → 老人/家属能看懂的一句话
  static String _humanize(String code) {
    switch (code) {
      case 'AuthFailure.SecretIdNotFound':
      case 'AuthFailure.SignatureFailure':
      case 'AuthFailure.InvalidSecretId':
        return 'SecretId 或 SecretKey 填错了，请再核对一遍';
      case 'AuthFailure.SignatureExpire':
        return '手机时间不准（和服务器差太多），请把手机时间调成自动';
      case 'AuthFailure.UnauthorizedOperation':
        return '这个账号没有语音识别权限，检查是否勾选了 QcloudASRFullAccess';
      case 'AuthFailure':
        return '密钥没有通过验证，请重新检查 SecretId / SecretKey';
      case 'FailedOperation.ServiceNotOpened':
      case 'FailedOperation.ServiceIsolate':
      case 'ResourceNotFound':
      case 'ResourceUnavailable.ServiceNotOpened':
        return '腾讯云语音识别还没开通，去控制台点一下「开通服务」';
      case 'FailedOperation.UserHasNoFreeAmount':
      case 'FailedOperation.InArrears':
        return '本月免费额度用完了，或账号欠费';
      case 'RequestLimitExceeded':
        return '调用太频繁，过一会儿再试';
      case 'FailedOperation.ErrorRecognize':
        return '这段没听清，再说一次';
      default:
        return '识别服务返回错误：$code';
    }
  }

  static bool _isAuthProblem(String code) {
    if (code.startsWith('AuthFailure')) return true;
    if (code == 'FailedOperation.ServiceNotOpened') return true;
    if (code == 'FailedOperation.ServiceIsolate') return true;
    if (code == 'FailedOperation.UserHasNoFreeAmount') return true;
    if (code == 'FailedOperation.InArrears') return true;
    if (code == 'ResourceNotFound') return true;
    return false;
  }

  // ------------------------------------------------------------ TC3 签名

  /// 腾讯云 TC3-HMAC-SHA256 签名
  ///
  /// 步骤（官方文档「签名方法 v3」）：
  /// 1. 拼规范请求串 → 2. 拼待签字符串 → 3. 逐级派生签名密钥 → 4. 拼 Authorization
  ///
  /// 这里只签 content-type 与 host 两个头，够用且最不容易出错。
  static String _authorization(String payload, int timestamp) {
    final AppSettings s = AppSettings.instance;
    final String secretId = s.asrSecretId.trim();
    final String secretKey = s.asrSecretKey.trim();

    // 日期必须用 UTC（用本地时间会导致晚上 8 点后签名过期）
    final DateTime utc =
        DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
    final String date = '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';

    const String signedHeaders = 'content-type;host';
    final String canonicalHeaders =
        'content-type:$_contentType\nhost:$_host\n';

    final String canonicalRequest = 'POST\n'
        '/\n'
        '\n'
        '$canonicalHeaders'
        '\n'
        '$signedHeaders\n'
        '${_sha256Hex(payload)}';

    final String scope = '$date/$_service/tc3_request';
    final String stringToSign = 'TC3-HMAC-SHA256\n'
        '$timestamp\n'
        '$scope\n'
        '${_sha256Hex(canonicalRequest)}';

    final List<int> kDate = _hmac(utf8.encode('TC3$secretKey'), date);
    final List<int> kService = _hmac(kDate, _service);
    final List<int> kSigning = _hmac(kService, 'tc3_request');
    final String signature = _hex(_hmac(kSigning, stringToSign));

    return 'TC3-HMAC-SHA256 '
        'Credential=$secretId/$scope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';
  }

  static String _sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  static List<int> _hmac(List<int> key, String msg) =>
      Hmac(sha256, key).convert(utf8.encode(msg)).bytes;

  static String _hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}
