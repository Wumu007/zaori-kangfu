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

  bool _largeText = false;
  int _snoozeMinutes = 10;
  bool _confirmBeforeSkip = true;

  bool get largeText => _largeText;
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
}

