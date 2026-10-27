import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'app_settings.dart';
import 'backup_service.dart';
import 'native_bridge.dart';

/// 恢复结果（用于启动日志与设置页展示）
class VaultRestoreResult {
  const VaultRestoreResult({
    this.meds = 0,
    this.logs = 0,
    this.keyRestored = false,
    this.reason = '',
  });

  final int meds;
  final int logs;
  final bool keyRestored;

  /// 说明（没恢复时写原因，方便排查）
  final String reason;

  bool get didSomething => meds > 0 || logs > 0 || keyRestored;
}

/// 数据保险箱（V1.15.0）
///
/// ═══════════════════════════════════════════════════════════════════
/// 它解决两个真实痛点
/// ═══════════════════════════════════════════════════════════════════
///
/// 用户第 8 份日志：
///   [PERM]   权限快照 | 通知=false 精确闹钟=true 电池白名单=false
///   [NOTIFY] 排程汇总 | 成功 0 条 / 失败 0 条 / 在提醒 0 种药
///
/// 「在提醒 0 种药」不是排程坏了，而是**重装后本地数据库是空的** ——
/// 一种药都没有，自然排不出提醒。同一类问题还有一个：每次重装都要
/// 重新填腾讯云密钥。
///
/// 根因相同：所有数据（药品、记录、设置、密钥）都只存在应用私有目录，
/// 卸载即删。系统级 Auto Backup 在国产 ROM + 侧载安装上基本不生效，
/// 所以这里自己写一份到 `Android/media/<包名>/zaori-vault.json`
/// （该目录卸载不删，且应用读写自己的子目录不需要任何权限）。
///
/// 策略：
/// - **写**：药品/记录变化后自动备份（2 秒去抖），保存密钥后立即备份；
/// - **读**：冷启动时，如果本机「没有药」或「没有密钥」，才从保险箱恢复
///   （有数据时绝不覆盖，避免把用户新加的覆盖掉）。
class VaultService {
  VaultService._();
  static final VaultService instance = VaultService._();

  Timer? _debounce;
  bool _saving = false;

  /// 最近一次备份时间（设置页展示）
  DateTime? lastSavedAt;
  String lastPath = '';

  /// 去抖保存：数据变化很频繁（每次排程都会触发），不能每次都写盘
  void scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => save());
  }

  /// 立即备份
  Future<void> save() async {
    if (_saving) return;
    _saving = true;
    try {
      final String json = await BackupService.instance.buildBackupJson(
        extra: <String, Object?>{
          // 密钥只进保险箱，不进用户手动导出的文件
          'vaultSettings': AppSettings.instance.vaultSettings(),
        },
      );
      final String? path = await NativeBridge.vaultSave(json);
      if (path != null) {
        lastPath = path;
        lastSavedAt = DateTime.now();
        AppLog.instance.log(
          LogTag.app,
          '保险箱已备份',
          '${json.length} 字节 → $path',
        );
      } else {
        AppLog.instance.log(LogTag.app, '保险箱备份失败', '原生返回 null');
      }
    } catch (e) {
      AppLog.instance.error('保险箱备份异常', e);
    } finally {
      _saving = false;
    }
  }

  /// 冷启动恢复：只在「本机缺数据」时动手
  Future<VaultRestoreResult> restoreIfNeeded() async {
    if (!NativeBridge.supported) {
      return const VaultRestoreResult(reason: '非 Android 平台');
    }
    try {
      final bool exists = await NativeBridge.vaultExists;
      if (!exists) {
        return const VaultRestoreResult(reason: '还没有备份');
      }

      final String? raw = await NativeBridge.vaultLoad();
      if (raw == null || raw.isEmpty) {
        return const VaultRestoreResult(reason: '备份文件是空的');
      }

      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map<String, Object?>) {
        return const VaultRestoreResult(reason: '备份格式不对');
      }

      final int localMeds = await BackupService.instance.medicationCount();
      final bool noKey = AppSettings.instance.asrSecretId.trim().isEmpty;

      // 本机有药 + 有密钥 → 什么都不做（绝不覆盖用户现状）
      if (localMeds > 0 && !noKey) {
        return const VaultRestoreResult(reason: '本机已有数据，跳过');
      }

      VaultRestoreResult result = const VaultRestoreResult();

      // 1) 药品与记录：本机为空时才导入
      if (localMeds == 0) {
        final ({int meds, int logs}) r =
            await BackupService.instance.importFromJson(raw);
        result = VaultRestoreResult(
          meds: r.meds,
          logs: r.logs,
          reason: '从保险箱恢复',
        );
        AppLog.instance.log(
          LogTag.app,
          '保险箱已恢复',
          '药品 ${r.meds} 种 / 记录 ${r.logs} 条',
        );
      }

      // 2) 设置与密钥：本机没有密钥时才恢复
      final Object? vs = parsed['vaultSettings'];
      if (noKey && vs is Map<String, Object?>) {
        final bool ok = await AppSettings.instance.applyVaultSettings(vs);
        if (ok) {
          AppLog.instance.log(LogTag.app, '保险箱已恢复密钥', '在线识别按原设置启用');
        }
        result = VaultRestoreResult(
          meds: result.meds,
          logs: result.logs,
          keyRestored: ok,
          reason: result.reason.isEmpty ? '恢复设置' : result.reason,
        );
      }

      return result;
    } catch (e) {
      AppLog.instance.error('保险箱恢复异常', e);
      return VaultRestoreResult(reason: '$e');
    }
  }

  /// 保险箱文件路径（设置页展示）
  Future<String> path() async {
    if (lastPath.isNotEmpty) return lastPath;
    final String p = await NativeBridge.vaultPath();
    if (p.isNotEmpty) lastPath = p;
    return p;
  }

  /// 删除保险箱
  Future<bool> clear() async {
    final bool ok = await NativeBridge.clearVault();
    if (ok) {
      lastSavedAt = null;
      AppLog.instance.log(LogTag.app, '保险箱已清除');
    }
    return ok;
  }

  /// 仅调试用：打印当前保险箱大小
  Future<int> sizeBytes() async {
    final String json = await NativeBridge.vaultLoad() ?? '';
    return json.length;
  }
}
