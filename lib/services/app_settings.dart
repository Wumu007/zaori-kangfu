import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地设置（纯本地，不上云）
///
/// 只放真正会影响行为的设置 —— 每个开关都必须立刻生效，
/// 不做「设了但没反应」的假设置：
/// 1. [largeText]         大字号：默认关闭（通用版），需要的人自己打开；
/// 2. [snoozeMinutes]     通知里「稍后提醒」的默认时长；
/// 3. [confirmBeforeSkip] 跳过本次前是否再问一句（防误触）。
///
/// V1.3 移除了 guestPin（家属查看功能整体下线）。
///
/// 故意不做「免打扰时段」：本地通知的免打扰要靠系统通道，做半套更容易误导用户，
/// 留给后续版本与通知开关一起做。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _kLargeText = 'setting_large_text';
  static const String _kSnooze = 'setting_snooze_minutes';
  static const String _kConfirmSkip = 'setting_confirm_skip';

  // V1.11.0：在线语音识别（腾讯云）—— 用户名下的密钥只存本机
  static const String _kAsrOnline = 'setting_asr_online';
  static const String _kAsrSecretId = 'setting_asr_secret_id';
  static const String _kAsrSecretKey = 'setting_asr_secret_key';

  bool _largeText = false;
  int _snoozeMinutes = 10;
  bool _confirmBeforeSkip = true;

  /// 是否启用在线识别（在线优先，失败回落离线）
  bool _asrOnlineEnabled = false;

  /// 腾讯云密钥：只存本机 SharedPreferences（应用私有目录）。
  /// 绝不写进代码、绝不进仓库 —— APK 分发出去等于公开密钥。
  String _asrSecretId = '';
  String _asrSecretKey = '';

  bool get largeText => _largeText;

  bool get asrOnlineEnabled => _asrOnlineEnabled;
  String get asrSecretId => _asrSecretId;
  String get asrSecretKey => _asrSecretKey;

  /// 在线识别的两个前提：开关打开 + 密钥填齐
  bool get asrOnlineReady =>
      _asrOnlineEnabled &&
      _asrSecretId.trim().isNotEmpty &&
      _asrSecretKey.trim().isNotEmpty;
  int get snoozeMinutes => _snoozeMinutes;
  bool get confirmBeforeSkip => _confirmBeforeSkip;

  /// 全局字号倍率：只在 app.dart 的 MediaQuery 里用一次
  double get textScale => _largeText ? 1.18 : 1.0;

  /// 启动时读一次；读失败就用默认值，不阻塞启动
  Future<void> load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      _largeText = sp.getBool(_kLargeText) ?? false;
      _snoozeMinutes = sp.getInt(_kSnooze) ?? 10;
      _confirmBeforeSkip = sp.getBool(_kConfirmSkip) ?? true;
      _asrOnlineEnabled = sp.getBool(_kAsrOnline) ?? false;
      _asrSecretId = sp.getString(_kAsrSecretId) ?? '';
      _asrSecretKey = sp.getString(_kAsrSecretKey) ?? '';
      notifyListeners();
    } catch (_) {
      // 首次安装或存储不可用时静默降级
    }
  }

  Future<void> setLargeText(bool value) async {
    if (_largeText == value) return;
    _largeText = value;
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setBool(_kLargeText, value);
  }

  Future<void> setSnoozeMinutes(int value) async {
    if (_snoozeMinutes == value) return;
    _snoozeMinutes = value;
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setInt(_kSnooze, value);
  }

  Future<void> setConfirmBeforeSkip(bool value) async {
    if (_confirmBeforeSkip == value) return;
    _confirmBeforeSkip = value;
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setBool(_kConfirmSkip, value);
  }

  /// 开关在线识别。没有密钥时不允许打开（否则用户会以为开了却没用）。
  Future<bool> setAsrOnlineEnabled(bool value) async {
    if (value &&
        (_asrSecretId.trim().isEmpty || _asrSecretKey.trim().isEmpty)) {
      return false;
    }
    if (_asrOnlineEnabled == value) return true;
    _asrOnlineEnabled = value;
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAsrOnline, value);
    return true;
  }

  /// 保存腾讯云密钥（用户手动粘贴）
  Future<void> saveAsrCredentials({
    required String secretId,
    required String secretKey,
  }) async {
    _asrSecretId = secretId.trim();
    _asrSecretKey = secretKey.trim();
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kAsrSecretId, _asrSecretId);
    await sp.setString(_kAsrSecretKey, _asrSecretKey);
  }

  // ------------------------------------------------ 保险箱：设置快照

  /// 导出可写进保险箱的设置片段（V1.15.0）
  ///
  /// 只放「重装后重新配置最麻烦」的几项：腾讯云密钥、在线识别开关、
  /// 提醒间隔、字号。其他项无关紧要，不扩大备份面。
  Map<String, Object?> vaultSettings() => <String, Object?>{
        'asrOnline': _asrOnlineEnabled,
        'asrSecretId': _asrSecretId,
        'asrSecretKey': _asrSecretKey,
        'snoozeMinutes': _snoozeMinutes,
        'largeText': _largeText,
      };

  /// 从保险箱恢复设置（只恢复「本机现在还是空」的那部分，不覆盖用户
  /// 刚改过的值）
  Future<bool> applyVaultSettings(Map<String, Object?> v) async {
    bool changed = false;
    final String id = (v['asrSecretId'] as String? ?? '').trim();
    final String key = (v['asrSecretKey'] as String? ?? '').trim();
    if (_asrSecretId.isEmpty && _asrSecretKey.isEmpty && id.isNotEmpty) {
      await saveAsrCredentials(secretId: id, secretKey: key);
      final bool online = v['asrOnline'] as bool? ?? false;
      if (online) await setAsrOnlineEnabled(true);
      changed = true;
    }
    return changed;
  }

  /// 清除密钥，同时关闭在线识别
  Future<void> clearAsrCredentials() async {
    _asrSecretId = '';
    _asrSecretKey = '';
    _asrOnlineEnabled = false;
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.remove(_kAsrSecretId);
    await sp.remove(_kAsrSecretKey);
    await sp.setBool(_kAsrOnline, false);
  }
}

