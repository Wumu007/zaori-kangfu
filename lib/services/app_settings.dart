import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地设置（纯本地，不上云）
///
/// V1 只放三项真正会影响行为的设置：
/// 1. [largeText]  大字号：默认关闭（通用版），需要的人自己打开；
/// 2. [snoozeMinutes] 通知里「延后」的默认时长；
/// 3. [guestPin] 家属访客视图的 4 位查看密码（null = 未设置）。
///
/// 故意不做「免打扰时段」：本地通知的免打扰要靠系统通道，做半套更容易误导用户，
/// 留给 V2 与通知开关一起做。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _kLargeText = 'setting_large_text';
  static const String _kSnooze = 'setting_snooze_minutes';
  static const String _kGuestPin = 'setting_guest_pin';

  bool _largeText = false;
  int _snoozeMinutes = 10;
  String? _guestPin;

  bool get largeText => _largeText;
  int get snoozeMinutes => _snoozeMinutes;
  String? get guestPin => _guestPin;

  /// 全局字号倍率：只在 main.dart 的 MediaQuery 里用一次
  double get textScale => _largeText ? 1.18 : 1.0;

  /// 启动时读一次；读失败就用默认值，不阻塞启动
  Future<void> load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      _largeText = sp.getBool(_kLargeText) ?? false;
      _snoozeMinutes = sp.getInt(_kSnooze) ?? 10;
      _guestPin = sp.getString(_kGuestPin);
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

  /// 传 null 表示清除密码（清除后访客视图关闭）
  Future<void> setGuestPin(String? pin) async {
    _guestPin = pin;
    notifyListeners();
    final SharedPreferences sp = await SharedPreferences.getInstance();
    if (pin == null || pin.isEmpty) {
      await sp.remove(_kGuestPin);
    } else {
      await sp.setString(_kGuestPin, pin);
    }
  }

  /// 校验访客密码；未设置密码时一律不允许进入
  bool verifyPin(String input) {
    final String? pin = _guestPin;
    if (pin == null || pin.isEmpty) return false;
    return pin == input;
  }
}
