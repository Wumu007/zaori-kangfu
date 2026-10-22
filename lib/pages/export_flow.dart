import 'dart:async';

import 'package:flutter/material.dart';

import '../services/backup_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

/// 导出区间的三种预设
///
/// 不做「自定义起止日期」：这类 App 的用户真实需求就是
/// 「给医生看最近一个月」或「换手机全带走」两种，多一个日期选择器只是多一个坎。
enum ExportRange {
  week('最近 7 天', 7),
  month('最近 30 天', 30),
  all('全部记录', 0);

  const ExportRange(this.label, this.days);

  final String label;

  /// 0 表示不限（从最早一条记录开始）
  final int days;
}

/// 导出流程的统一入口：选区 → 导出 → 告诉用户存哪了
///
/// 抽出来的理由：记录页和设置页都要导出，如果各写一遍，
/// 「存到哪了」这句话迟早会在其中一处漏掉 —— 而老人最需要的就是这句话。
class ExportFlow {
  ExportFlow._();

  /// 弹区间选择，然后导出服药记录（CSV + 纯文本摘要）
  static Future<void> records(BuildContext context) async {
    final ExportRange? range = await _askRange(context);
    if (range == null || !context.mounted) return;

    final DateTime now = DateTime.now();
    final DateTime to = DateTime(now.year, now.month, now.day);
    final DateTime from = range.days == 0
        ? DateTime(2020, 1, 1) // 足够早，实际由「有没有记录」决定行数
        : to.subtract(Duration(days: range.days - 1));

    final String base = range.days == 0
        ? '服药记录_全部_${_stamp(to)}'
        : '服药记录_${_stamp(from)}_${_stamp(to)}';

    await _run(
      context,
      action: () => BackupService.instance.exportRecordsWithSummary(
        from: from,
        to: to,
        baseName: base,
      ),
      emptyHint: '这段时间没有可导出的记录。',
    );
  }

  /// 导出药品清单（CSV）
  static Future<void> medications(BuildContext context) async {
    final DateTime now = DateTime.now();
    await _run(
      context,
      action: () async {
        final ExportResult? r = await BackupService.instance.exportMedications(
          suggestedName: '药品清单_${_stamp(now)}.csv',
        );
        return r == null ? null : <ExportResult>[r];
      },
      emptyHint: '还没有添加任何药品。',
    );
  }

  /// 导出完整备份（换手机用）
  static Future<void> backup(BuildContext context) async {
    final DateTime now = DateTime.now();
    await _run(
      context,
      action: () async {
        final ExportResult? r = await BackupService.instance.exportBackup(
          suggestedName: '早日康复备份_${_stamp(now)}.json',
        );
        return r == null ? null : <ExportResult>[r];
      },
      emptyHint: '本机还没有任何数据可以备份。',
    );
  }

  // ------------------------------------------------------------ 内部

  /// 单次导出/导入的最长等待。兜底用：正常导出几秒内完成，
  /// 超时只可能发生在系统「保存到」界面卡死或 ROM 拦截文件的极端情况。
  /// 没有这个兜底时遮罩会永远挂着，整个界面像死机 —— V1.2 的实际反馈。
  static const Duration _timeout = Duration(seconds: 60);

  static Future<void> _run(
    BuildContext context, {
    required Future<List<ExportResult>?> Function() action,
    required String emptyHint,
  }) async {
    _lastAction = action; // 记下这次用的动作，失败弹窗里的「重试」复用它
    final _BusyHandle busy = _BusyHandle.show(context, '正在整理数据…');
    List<ExportResult>? results;
    Object? failure;
    try {
      results = await action().timeout(_timeout);
    } catch (e) {
      failure = e;
    } finally {
      // 无论成功失败超时，遮罩必须关掉 —— 放在 finally 里保证任何路径都不漏
      busy.close();
    }
    if (!context.mounted) return;

    if (failure != null) {
      await _showFailure(context, failure);
      return;
    }

    // null = 用户在自己的「保存到」界面点了取消。什么都不说，
    // 用户知道自己在做什么，弹一句「已取消」纯属打扰。
    if (results == null) return;

    final int total = results.fold<int>(0, (int s, ExportResult r) => s + r.rows);
    if (total == 0 || results.isEmpty) {
      showAppToast(context, emptyHint);
      return;
    }

    await _showDone(context, results);
  }

  /// 失败弹窗：给「换个位置重试」的出路，而不是只弹一句 toast 让用户自己找入口
  static Future<void> _showFailure(BuildContext context, Object error) {
    final bool timeout = error is TimeoutException;
    return showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(timeout ? '等待超时' : '导出失败'),
        content: Text(
          timeout
              ? '系统「保存到」界面长时间没有响应。\n\n'
                  '可以重试；如果总是超时，请重启手机后再试。'
              : '所选位置可能没有写入权限。\n\n'
                  '建议：在「保存到」界面选择「下载」或「文档」这类手机内置文件夹，'
                  '避免选 SD 卡或网盘目录。',
          style: const TextStyle(
            fontSize: AppText.caption,
            height: 1.7,
            color: AppColors.sub,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // 原样重跑一次（调用方的 action 闭包仍然有效）
              _retry(context);
            },
            child: const Text('重试', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// 上一次失败时用的 action，供「重试」复用
  static Future<List<ExportResult>?> Function()? _lastAction;

  static Future<void> _retry(BuildContext context) async {
    final Future<List<ExportResult>?> Function()? action = _lastAction;
    if (action == null) return;
    await _run(context, action: action, emptyHint: '没有可导出的内容。');
  }

  static Future<ExportRange?> _askRange(BuildContext context) {
    return showModalBottomSheet<ExportRange>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bg,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '导出服药记录',
                  style: TextStyle(
                    fontSize: AppText.h2,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '会同时生成两个文件：一份表格（CSV，可用 WPS 打开看和排序），'
                  '一份纯文字摘要（txt，适合直接发给家人看）。',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    height: 1.55,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 14),
                for (final ExportRange r in ExportRange.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(r),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          side: const BorderSide(color: AppColors.line),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          r.label,
                          style: const TextStyle(
                            fontSize: AppText.bodySm,
                            fontWeight: FontWeight.w500,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
                const Text(
                  '选好之后会弹出手机的「保存到」，你可以存进手机文件夹、微信收藏或网盘。',
                  style: TextStyle(
                    fontSize: AppText.tiny,
                    height: 1.55,
                    color: AppColors.faint,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<void> _showDone(
    BuildContext context,
    List<ExportResult> results,
  ) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('已导出'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final ExportResult r in results)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      r.title,
                      style: const TextStyle(
                        fontSize: AppText.caption,
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      r.fileName,
                      style: const TextStyle(
                        fontSize: AppText.tiny,
                        height: 1.5,
                        color: AppColors.sub,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 2),
            // 用户选的位置写不进去时，文件落在了应用专属目录，必须说明白
            if (results.any((ExportResult r) => r.path.contains('导出的文件')))
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warnSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '你选的文件夹不允许写入，文件已保存到应用文件夹「导出的文件」里'
                  '（见上方文件名）。要发给别人，可在微信里选择该文件发送。',
                  style: TextStyle(
                    fontSize: AppText.tiny,
                    height: 1.55,
                    color: AppColors.warn,
                  ),
                ),
              ),
            const Text(
              '文件已保存到你选的位置。\n'
              '用手机上的 WPS 或 Excel 打开表格就能看；纯文字那份可以直接发微信。',
              style: TextStyle(
                fontSize: AppText.tiny,
                height: 1.6,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 「处理中」遮罩：导出/导入可能读几千行，给个明确反馈
class _BusyHandle {
  _BusyHandle._(this._entry);

  final OverlayEntry _entry;

  static _BusyHandle show(BuildContext context, String text) {
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext ctx) => ColoredBox(
        color: const Color(0x66000000),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(height: 12),
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: AppText.caption,
                    color: AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final NavigatorState nav = Navigator.of(context);
    nav.overlay?.insert(entry);
    return _BusyHandle._(entry);
  }

  void close() {
    if (_entry.mounted) _entry.remove();
  }
}
